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
	inBase   bool        // commits are in the base branch, so unpushed ones aren't lost
	// Includes are the feature's -dev/-stg branches, removed along with it.
	Includes []CleanupInclude `json:"includes,omitempty"`
	parentID string
}

// CleanupInclude is an environment branch removed together with its feature.
type CleanupInclude struct {
	ID     string `json:"id"`
	Branch string `json:"branch"`
	Reason string `json:"reason"`
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
		case task.PR != nil && task.PR.State == "merged":
			kind, reason = CleanupMerged, fmt.Sprintf("PR #%d was merged", task.PR.Number)
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
			Dirty: task.Dirty, Running: task.Running + task.Waiting, inBase: task.Merged, parentID: task.ParentID,
		}
		if task.Missing {
			item.Dirty = 0
		}
		items = append(items, item)
	}
	items = groupEnvBranches(items)
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
			item.Safe = item.Dirty == 0 && (item.Unpushed == 0 || item.inBase) && item.Running == 0
			for _, include := range item.Includes {
				item.Unpushed += service.Git.Unpushed(item.Repo, include.Branch)
			}
			if len(item.Includes) > 0 && item.Unpushed > 0 {
				item.Safe = false
			}
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
		results = append(results, service.removeForCleanup(snapshot, item.ID, item.Title, progress)...)
		for _, include := range item.Includes {
			results = append(results, service.removeForCleanup(snapshot, include.ID, item.Title+" "+include.Branch, progress)...)
		}
	}
	return results, nil
}

// removeForCleanup removes one task's workspace, worktree and local branch, whatever is there.
func (service *Service) removeForCleanup(snapshot Snapshot, id, title string, progress Progress) []StepResult {
	task, err := FindTask(snapshot.Tasks, id)
	if err != nil {
		return []StepResult{stepFrom(title, err, "")}
	}
	plan := service.planFor(task)
	options := map[string]bool{OptCloseWorkspace: true, OptRemoveWorktree: true, OptDeleteBranch: true, OptSwitchMainToBase: true}
	for key := range options {
		options[key] = plan.Options[key].Available
	}
	steps, err := service.applyPlan(plan, RemoveRequest{Task: task.ID, Options: options, Confirm: task.Branch}, progress)
	if err != nil {
		return []StepResult{stepFrom(title, err, "")}
	}
	results := make([]StepResult, 0, len(steps))
	for _, step := range steps {
		step.Step = title + ": " + step.Step
		results = append(results, step)
	}
	return results
}

func stepFrom(step string, err error, okMessage string) StepResult {
	if err != nil {
		return StepResult{Step: step, Message: err.Error()}
	}
	return StepResult{Step: step, OK: true, Message: okMessage}
}

// groupEnvBranches folds merged/gone -dev and -stg items into their feature's item when the
// feature itself is merged, so the whole set goes in one step.
func groupEnvBranches(items []CleanupItem) []CleanupItem {
	feature := map[string]int{}
	for index, item := range items {
		if item.Kind == CleanupMerged && item.parentID == "" {
			feature[item.ID] = index
		}
	}
	absorbed := make([]bool, len(items))
	for index, item := range items {
		position, ok := feature[item.parentID]
		if item.parentID == "" || !ok || (item.Kind != CleanupMerged && item.Kind != CleanupGone) {
			continue
		}
		parent := &items[position]
		parent.Includes = append(parent.Includes, CleanupInclude{ID: item.ID, Branch: item.Branch, Reason: item.Reason})
		parent.Dirty += item.Dirty
		parent.Running += item.Running
		absorbed[index] = true
	}
	kept := make([]CleanupItem, 0, len(items))
	for index, item := range items {
		if !absorbed[index] {
			kept = append(kept, item)
		}
	}
	return kept
}
