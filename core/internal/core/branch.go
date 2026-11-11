package core

import (
	"strings"

	"fmt"

	"wk/internal/gitops"
)

// SwitchBranch checks out another (local or origin/…) branch in a task's worktree.
func (service *Service) SwitchBranch(taskQuery, branch string, stash bool) (string, error) {
	task, err := service.task(taskQuery)
	if err != nil {
		return "", err
	}
	if task.Path == "" {
		return "", fmt.Errorf("%s has no worktree to switch", task.ID)
	}
	if err := service.Ops.Switch(task.Path, branch, stash); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s is now on %s", task.Path, branch), nil
}

// RenameBranch renames the task's branch and carries over pins and notes.
func (service *Service) RenameBranch(taskQuery, newName string) (string, error) {
	task, err := service.task(taskQuery)
	if err != nil {
		return "", err
	}
	if task.IsBase {
		return "", fmt.Errorf("refusing to rename base branch %s", task.Branch)
	}
	if err := service.Ops.RenameBranch(task.Repo, task.Branch, newName); err != nil {
		return "", err
	}
	service.State.RenameTask(task.ID, TaskID(task.Repo, newName))
	if err := service.SaveState(); err != nil {
		return "", err
	}
	return fmt.Sprintf("Renamed %s to %s (the folder name stays %s)", task.Branch, newName, task.Path), nil
}

// Pull fast-forwards the task's worktree from its upstream.
func (service *Service) Pull(taskQuery string) (string, error) {
	task, err := service.task(taskQuery)
	if err != nil {
		return "", err
	}
	if task.Path == "" {
		if err := service.Ops.Fetch(task.Repo); err != nil {
			return "", err
		}
		return "Fetched (branch is not checked out, nothing to fast-forward)", nil
	}
	out, err := service.Ops.Pull(task.Path)
	if err != nil {
		return "", err
	}
	return out, nil
}

// AddWorktree creates a sibling worktree for an existing local or origin/ branch, or from the
// task's current HEAD under a new branch name.
func (service *Service) AddWorktree(repoQuery, branch, newBranch, base string, progress Progress) (NewTaskResult, error) {
	repo, err := service.ResolveRepo(repoQuery)
	if err != nil {
		return NewTaskResult{}, err
	}
	name := branch
	creating := newBranch != ""
	if creating {
		name = newBranch
		if err := service.Ops.ValidateBranchName(repo, name); err != nil {
			return NewTaskResult{}, err
		}
	}
	local := name
	if _, rest, ok := cutOrigin(name); ok {
		local = rest
	}
	path := gitops.WorktreePath(repo, local)
	progress.Step("Creating worktree %s", path)
	start := base
	if creating && start == "" {
		start = branch
	}
	if err := service.Ops.AddWorktree(repo, path, name, start, creating); err != nil {
		return NewTaskResult{}, err
	}
	setup := service.PrepareWorktree(repo, path, progress)
	return NewTaskResult{TaskID: TaskID(repo, local), Branch: local, Path: path, Base: start, SetupCmd: setup}, nil
}

func cutOrigin(name string) (string, string, bool) {
	const prefix = "origin/"
	if len(name) > len(prefix) && name[:len(prefix)] == prefix {
		return prefix, name[len(prefix):], true
	}
	return "", "", false
}

// SetPinned / SetHidden / SetNote update wk's own metadata for a task.
func (service *Service) SetPinned(taskQuery string, pinned bool) error {
	return service.updateTaskState(taskQuery, func(id string) { service.State.SetPinned(id, pinned) })
}

func (service *Service) SetHidden(taskQuery string, hidden bool) error {
	return service.updateTaskState(taskQuery, func(id string) { service.State.SetHidden(id, hidden) })
}

func (service *Service) SetNote(taskQuery, note string) error {
	return service.updateTaskState(taskQuery, func(id string) { service.State.SetNote(id, note) })
}

func (service *Service) updateTaskState(taskQuery string, update func(string)) error {
	task, err := service.task(taskQuery)
	if err != nil {
		return err
	}
	update(task.ID)
	return service.SaveState()
}

func (service *Service) task(query string) (Task, error) {
	snapshot, err := service.Snapshot()
	if err != nil {
		return Task{}, err
	}
	return FindTask(snapshot.Tasks, query)
}

// Show returns a task with recent commits and changed files for the detail pane.
type TaskDetail struct {
	Task    Task     `json:"task"`
	Log     []string `json:"log"`
	Changes []string `json:"changes"`
}

func (service *Service) Show(taskQuery string) (TaskDetail, error) {
	snapshot, err := service.SnapshotScoped(Scope{}) // cached repos are fine for a read-only detail view
	if err != nil {
		return TaskDetail{}, err
	}
	task, err := FindTask(snapshot.Tasks, taskQuery)
	if err != nil {
		return TaskDetail{}, err
	}
	detail := TaskDetail{Task: task}
	dir := task.Path
	if dir == "" {
		dir = task.Repo
	}
	ref := task.Branch
	if task.Detached {
		ref = "HEAD"
	}
	detail.Log = service.Git.Log(dir, ref, 8)
	if task.Path != "" && !task.Missing {
		detail.Changes = service.Git.WorktreeStatus(task.Repo, task.Path, task.Branch).Changes
	}
	return detail, nil
}

// RepoRefs lists what a new task can start from.
type RepoRefs struct {
	Repo       string   `json:"repo"`
	BaseBranch string   `json:"base_branch"`
	Local      []string `json:"local"`
	Remote     []string `json:"remote"`
	Worktrees  []string `json:"worktrees"`
	Suggested  string   `json:"suggested_prefix"` // e.g. ABC-
}

func (service *Service) RepoRefs(repoQuery string) (RepoRefs, error) {
	repo, err := service.ResolveRepo(repoQuery)
	if err != nil {
		return RepoRefs{}, err
	}
	refs := RepoRefs{Repo: repo, BaseBranch: service.repoSettings(repo).BaseBranch, Local: []string{}, Remote: []string{}, Worktrees: []string{}}
	branches, err := service.Git.Branches(repo)
	if err != nil {
		return refs, err
	}
	prefixCount := map[string]int{}
	for _, branch := range branches {
		refs.Local = append(refs.Local, branch.Name)
		if ticket := gitops.Ticket(branch.Name); ticket != "" {
			prefixCount[ticket[:strings.Index(ticket, "-")+1]]++
		}
	}
	refs.Remote, _ = service.Git.RemoteBranches(repo)
	if refs.Remote == nil {
		refs.Remote = []string{}
	}
	worktrees, _ := service.Git.Worktrees(repo)
	for _, worktree := range worktrees {
		if !worktree.Missing {
			refs.Worktrees = append(refs.Worktrees, worktree.Path)
		}
	}
	best := 0
	for prefix, count := range prefixCount {
		if count > best {
			refs.Suggested, best = prefix, count
		}
	}
	return refs, nil
}
