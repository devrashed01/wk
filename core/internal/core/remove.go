package core

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

type Option struct {
	Available bool   `json:"available"`
	Default   bool   `json:"default"`
	Reason    string `json:"reason,omitempty"` // why unavailable, or a warning
}

type RemoveFacts struct {
	Dirty        int        `json:"dirty"`
	Changes      []string   `json:"changes,omitempty"`
	Unpushed     int        `json:"unpushed"`
	HasRemote    bool       `json:"has_remote"`
	Merged       bool       `json:"merged"`
	Sessions     int        `json:"sessions"`
	LiveSessions int        `json:"live_sessions"`
	Workspace    *Workspace `json:"workspace,omitempty"`
	MainWorktree bool       `json:"main_worktree"`
	MainDirty    int        `json:"main_dirty"` // when the branch is checked out in the main worktree
}

type RemovePlan struct {
	Task            Task              `json:"task"`
	Facts           RemoveFacts       `json:"facts"`
	Options         map[string]Option `json:"options"`
	RequiresConfirm bool              `json:"requires_confirm"` // type the branch name to proceed
	Blocked         string            `json:"blocked,omitempty"`
}

// Option keys (also CLI flag names).
const (
	OptCloseWorkspace   = "close_workspace"
	OptSwitchMainToBase = "switch_main_to_base"
	OptRemoveWorktree   = "remove_worktree"
	OptDeleteBranch     = "delete_branch"
	OptDeleteRemote     = "delete_remote"
	OptTrashSessions    = "trash_sessions"
)

type RemoveRequest struct {
	Task    string          `json:"task"`
	Options map[string]bool `json:"options"`
	Confirm string          `json:"confirm,omitempty"`
}

type StepResult struct {
	Step    string `json:"step"`
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

// PlanRemove inspects a task and returns what can be removed, with safe defaults.
func (service *Service) PlanRemove(taskQuery string) (RemovePlan, error) {
	task, err := service.task(taskQuery)
	if err != nil {
		return RemovePlan{}, err
	}
	return service.planFor(task), nil
}

func (service *Service) planFor(task Task) RemovePlan {
	plan := RemovePlan{Task: task, Options: map[string]Option{}}
	facts := &plan.Facts
	status := service.Git.WorktreeStatus(task.Repo, existingPath(task), task.Branch)
	facts.Dirty, facts.Changes = status.Dirty, status.Changes
	facts.HasRemote, facts.Merged = status.HasRemote, task.Merged
	if !task.Detached {
		facts.Unpushed = status.Unpushed
	}
	facts.Sessions = len(task.Sessions)
	for _, session := range task.Sessions {
		if session.State == StateRunning || session.State == StateWaiting {
			facts.LiveSessions++
		}
	}
	facts.Workspace = task.Workspace
	facts.MainWorktree = task.MainWorktree

	plan.Options[OptCloseWorkspace] = Option{Available: task.Workspace != nil, Default: task.Workspace != nil}
	switch {
	case task.Path == "":
		plan.Options[OptRemoveWorktree] = Option{Reason: "branch is not checked out in any worktree"}
	case task.MainWorktree:
		plan.Options[OptRemoveWorktree] = Option{Reason: "this is the main repository folder; it is never removed"}
	default:
		// Pre-ticked only when nothing would be lost; the user can still opt in (and must confirm).
		option := Option{Available: true, Default: facts.Dirty == 0}
		if task.Missing {
			option.Reason = "folder already gone; this prunes git's record of it"
			option.Default = true
		} else if facts.Dirty > 0 {
			option.Reason = plural(facts.Dirty, "uncommitted change", "uncommitted changes") + " will be lost"
		}
		plan.Options[OptRemoveWorktree] = option
	}

	switch {
	case task.Detached:
		plan.Options[OptDeleteBranch] = Option{Reason: "detached HEAD has no branch"}
	case task.IsBase:
		plan.Options[OptDeleteBranch] = Option{Reason: "base branches are never deleted"}
	default:
		// Pre-ticked only when the commits are safe elsewhere: merged, or pushed to origin.
		option := Option{Available: true, Default: facts.Unpushed == 0 && (facts.Merged || facts.HasRemote)}
		// git can't delete a branch that's still checked out, so it follows the folder's default.
		if worktree, ok := plan.Options[OptRemoveWorktree]; ok && worktree.Available && !worktree.Default {
			option.Default = false
		}
		if facts.Unpushed > 0 {
			option.Reason = plural(facts.Unpushed, "commit exists", "commits exist") + " only on this branch and will be lost"
		} else if !facts.Merged && !facts.HasRemote {
			option.Reason = "not merged and not on origin; its commits would only survive in the reflog"
		}
		plan.Options[OptDeleteBranch] = option
		if task.MainWorktree {
			mainDirty := facts.Dirty
			facts.MainDirty = mainDirty
			switchOption := Option{Available: mainDirty == 0, Default: mainDirty == 0}
			if mainDirty > 0 {
				switchOption.Reason = "main folder has uncommitted changes; commit or stash first"
				option.Available, option.Default = false, false
				option.Reason = "branch is checked out in the main folder, which has uncommitted changes"
				plan.Options[OptDeleteBranch] = option
			} else {
				switchOption.Reason = "required to delete the branch: the main folder moves to " + service.repoSettings(task.Repo).BaseBranch
			}
			plan.Options[OptSwitchMainToBase] = switchOption
		}
	}
	plan.Options[OptDeleteRemote] = Option{Available: facts.HasRemote && !task.IsBase && !task.Detached, Default: false}
	if !facts.HasRemote {
		plan.Options[OptDeleteRemote] = Option{Reason: "no origin/" + task.Branch}
	}
	trashOption := Option{Available: facts.Sessions > facts.LiveSessions, Default: false}
	if facts.LiveSessions > 0 {
		trashOption.Reason = plural(facts.LiveSessions, "running session is", "running sessions are") + " kept"
	}
	plan.Options[OptTrashSessions] = trashOption

	plan.RequiresConfirm = plan.Options[OptRemoveWorktree].Available && facts.Dirty > 0 ||
		plan.Options[OptDeleteBranch].Available && facts.Unpushed > 0
	plan.Blocked = service.blockedReason(task)
	return plan
}

// blockedReason prevents wk from deleting the folder or workspace it is running in.
func (service *Service) blockedReason(task Task) string {
	if task.Path == "" || task.MainWorktree {
		return ""
	}
	if cwd, err := os.Getwd(); err == nil && (cwd == task.Path || strings.HasPrefix(cwd, task.Path+"/")) {
		return "you are running wk from inside this worktree; run it from somewhere else"
	}
	if task.Workspace != nil && strings.EqualFold(os.Getenv("CMUX_WORKSPACE_ID"), task.Workspace.ID) {
		return "this terminal is inside the task's cmux workspace; run it from another workspace or the menu-bar app"
	}
	return ""
}

func existingPath(task Task) string {
	if task.Path == "" || task.Missing {
		return ""
	}
	return task.Path
}

// ApplyRemove executes the chosen options in a safe order.
func (service *Service) ApplyRemove(request RemoveRequest, progress Progress) ([]StepResult, error) {
	task, err := service.task(request.Task)
	if err != nil {
		return nil, err
	}
	return service.applyPlan(service.planFor(task), request, progress)
}

func (service *Service) applyPlan(plan RemovePlan, request RemoveRequest, progress Progress) ([]StepResult, error) {
	task := plan.Task
	if plan.Blocked != "" {
		return nil, errors.New(plan.Blocked)
	}
	chosen := func(key string) bool {
		value, set := request.Options[key]
		if !set {
			value = plan.Options[key].Default
		}
		return value && plan.Options[key].Available
	}
	for key, value := range request.Options {
		if value && !plan.Options[key].Available {
			return nil, fmt.Errorf("%s is not possible: %s", key, plan.Options[key].Reason)
		}
	}
	destructive := chosen(OptRemoveWorktree) && plan.Facts.Dirty > 0 || chosen(OptDeleteBranch) && plan.Facts.Unpushed > 0
	if destructive && request.Confirm != task.Branch {
		return nil, fmt.Errorf("this loses uncommitted changes or unpushed commits; confirm by typing the branch name %q", task.Branch)
	}
	if chosen(OptDeleteBranch) && task.MainWorktree && !chosen(OptSwitchMainToBase) {
		return nil, errors.New("deleting a branch checked out in the main folder requires switch_main_to_base")
	}

	var results []StepResult
	record := func(step string, err error, okMessage string) bool {
		result := StepResult{Step: step, OK: err == nil, Message: okMessage}
		if err != nil {
			result.Message = err.Error()
			progress.Warn("%s failed: %v", step, err)
		} else {
			progress.Step("%s", okMessage)
		}
		results = append(results, result)
		return err == nil
	}

	if chosen(OptCloseWorkspace) {
		record(OptCloseWorkspace, service.Cmux.Close(task.Workspace.ID), "Closed cmux workspace "+task.Workspace.Title)
	}
	if chosen(OptSwitchMainToBase) && chosen(OptDeleteBranch) {
		base := service.repoSettings(task.Repo).BaseBranch
		if !record(OptSwitchMainToBase, service.Ops.Switch(task.Repo, base, false), "Switched main folder to "+base) {
			return results, nil
		}
	}
	if chosen(OptRemoveWorktree) {
		if !record(OptRemoveWorktree, service.Ops.RemoveWorktree(task.Repo, task.Path, plan.Facts.Dirty > 0), "Removed worktree "+task.Path) {
			return results, nil // keep the branch if its worktree is still there
		}
	}
	if chosen(OptDeleteBranch) {
		record(OptDeleteBranch, service.Ops.DeleteBranch(task.Repo, task.Branch, true), "Deleted branch "+task.Branch)
	}
	if chosen(OptDeleteRemote) {
		record(OptDeleteRemote, service.Ops.DeleteRemoteBranch(task.Repo, task.Branch), "Deleted origin/"+task.Branch)
	}
	if chosen(OptTrashSessions) {
		trashed := 0
		var failures []string
		for _, session := range task.Sessions {
			if session.State == StateRunning || session.State == StateWaiting {
				continue
			}
			if err := service.trash(session.ID); err != nil {
				failures = append(failures, err.Error())
				continue
			}
			trashed++
		}
		var err error
		if len(failures) > 0 {
			err = errors.New(strings.Join(failures, "; "))
		}
		record(OptTrashSessions, err, "Moved "+plural(trashed, "session", "sessions")+" to trash (restorable)")
	}
	return results, nil
}

// plural formats "1 file" / "2 files".
func plural(count int, one, many string) string {
	if count == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", count, many)
}
