package core

import (
	"fmt"
	"sync"
	"time"
)

type CleanupKind string

const (
	CleanupMerged          CleanupKind = "merged"           // merged into the base branch
	CleanupGone            CleanupKind = "gone"             // upstream deleted (usually after a PR merge)
	CleanupMissingWorktree CleanupKind = "missing_worktree" // folder deleted, git still tracks it
	CleanupStale           CleanupKind = "stale"            // no commits or Claude activity for a long time
	CleanupOrphanSession   CleanupKind = "orphan_session"   // session whose folder/branch is gone
)

const staleDays = 60

type CleanupItem struct {
	ID       string      `json:"id"` // task id or session id
	Kind     CleanupKind `json:"kind"`
	Repo     string      `json:"repo"`
	RepoName string      `json:"repo_name"`
	Branch   string      `json:"branch,omitempty"`
	Path     string      `json:"path,omitempty"`
	Title    string      `json:"title"`
	Reason   string      `json:"reason"`
	Safe     bool        `json:"safe"` // nothing would be lost
	Dirty    int         `json:"dirty"`
	Unpushed int         `json:"unpushed"`
	Last     time.Time   `json:"last"`
	Running  int         `json:"-"`
}

// Cleanup lists suggested removals. Nothing is changed.
func (service *Service) Cleanup() ([]CleanupItem, error) {
	snapshot, err := service.Snapshot()
	if err != nil {
		return nil, err
	}
	var items []CleanupItem
	staleCutoff := time.Now().AddDate(0, 0, -staleDays)
	for _, task := range snapshot.Tasks {
		if task.IsBase || task.Detached || task.Pinned {
			continue
		}
		kind, reason := CleanupKind(""), ""
		switch {
		case task.Missing:
			kind, reason = CleanupMissingWorktree, "worktree folder was deleted"
		case task.Merged:
			kind, reason = CleanupMerged, "merged into "+service.repoSettings(task.Repo).BaseBranch
		case task.Gone:
			kind, reason = CleanupGone, "remote branch was deleted (PR likely merged)"
		case task.LastActivity.Before(staleCutoff) && task.Running+task.Waiting == 0:
			kind, reason = CleanupStale, fmt.Sprintf("no commits or Claude activity for %d+ days", staleDays)
		default:
			continue
		}
		item := CleanupItem{
			ID: task.ID, Kind: kind, Repo: task.Repo, RepoName: task.RepoName, Branch: task.Branch,
			Path: task.Path, Title: task.RepoLabel + " " + task.Branch, Reason: reason, Last: task.LastActivity,
			Dirty: task.Dirty, Running: task.Running + task.Waiting,
		}
		if task.Missing {
			item.Dirty = 0
		}
		items = append(items, item)
	}
	// Unpushed checks are one git call per branch: run them in parallel.
	var group sync.WaitGroup
	limit := make(chan struct{}, 8)
	for index := range items {
		group.Add(1)
		go func() {
			defer group.Done()
			limit <- struct{}{}
			defer func() { <-limit }()
			item := &items[index]
			item.Unpushed = service.Git.Unpushed(item.Repo, item.Branch)
			item.Safe = item.Dirty == 0 && (item.Unpushed == 0 || item.Kind == CleanupMerged) && item.Running == 0
		}()
	}
	group.Wait()
	for _, session := range service.allSessions {
		if session.State != StateOrphan {
			continue
		}
		items = append(items, CleanupItem{
			ID: session.ID, Kind: CleanupOrphanSession, Repo: session.Repo, Branch: session.Branch, Path: session.Cwd,
			Title: session.DisplayTitle(), Reason: orphanReason(session), Safe: true, Last: session.Last,
		})
	}
	return items, nil
}

func orphanReason(session Session) string {
	if !session.CwdExists {
		return "its folder no longer exists"
	}
	return "its branch no longer exists"
}

// ApplyCleanup removes the selected items. Unsafe items are skipped unless force is set.
func (service *Service) ApplyCleanup(ids []string, force bool, progress Progress) ([]StepResult, error) {
	items, err := service.Cleanup()
	if err != nil {
		return nil, err
	}
	byID := map[string]CleanupItem{}
	for _, item := range items {
		byID[item.ID] = item
	}
	snapshot, err := service.Snapshot()
	if err != nil {
		return nil, err
	}
	var results []StepResult
	for _, id := range ids {
		item, ok := byID[id]
		if !ok {
			results = append(results, StepResult{Step: id, Message: "not a cleanup candidate (anymore)"})
			continue
		}
		if !item.Safe && !force {
			results = append(results, StepResult{Step: id, Message: fmt.Sprintf("skipped: %d uncommitted, %d unpushed (use force)", item.Dirty, item.Unpushed)})
			continue
		}
		if item.Kind == CleanupOrphanSession {
			err := service.trash(item.ID)
			results = append(results, stepFrom(item.Title, err, "Moved session to trash"))
			continue
		}
		task, err := FindTask(snapshot.Tasks, item.ID)
		if err != nil {
			results = append(results, stepFrom(item.Title, err, ""))
			continue
		}
		plan := service.planFor(task)
		options := map[string]bool{OptCloseWorkspace: true, OptRemoveWorktree: true, OptDeleteBranch: true, OptSwitchMainToBase: true}
		for key := range options {
			options[key] = plan.Options[key].Available
		}
		steps, err := service.applyPlan(plan, RemoveRequest{Task: task.ID, Options: options, Confirm: task.Branch}, progress)
		if err != nil {
			results = append(results, stepFrom(item.Title, err, ""))
			continue
		}
		for _, step := range steps {
			step.Step = item.Title + ": " + step.Step
			results = append(results, step)
		}
	}
	return results, nil
}

func stepFrom(step string, err error, okMessage string) StepResult {
	if err != nil {
		return StepResult{Step: step, Message: err.Error()}
	}
	return StepResult{Step: step, OK: true, Message: okMessage}
}
