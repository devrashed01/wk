package core

import (
	"errors"
	"fmt"
	"path/filepath"

	"wk/internal/config"
	"wk/internal/gitops"
)

type StartFrom string

const (
	FromBase     StartFrom = "base"     // the repo's base branch (production)
	FromLocal    StartFrom = "local"    // an existing local branch (Ref)
	FromRemote   StartFrom = "remote"   // a remote branch, e.g. origin/staging (Ref)
	FromWorktree StartFrom = "worktree" // HEAD of an existing worktree (Ref = worktree path)
)

type CreateMode string

const (
	ModeInPlace  CreateMode = "in-place" // switch an existing worktree to the new branch
	ModeWorktree CreateMode = "worktree" // new sibling worktree <repo>-<slug>
)

type NewTaskRequest struct {
	Repo   string     `json:"repo"`             // repo path or name (frontend/admin)
	Name   string     `json:"name"`             // new branch name
	From   StartFrom  `json:"from,omitempty"`   // default base
	Ref    string     `json:"ref,omitempty"`    // branch / remote branch / worktree path for From
	Mode   CreateMode `json:"mode,omitempty"`   // default worktree
	Target string     `json:"target,omitempty"` // in-place: worktree to switch (default main)
	Stash  bool       `json:"stash,omitempty"`
	Setup  *bool      `json:"setup,omitempty"` // run env copy + install (default true for worktree mode)
	Open   OpenMode   `json:"open,omitempty"`  // after creating: new (default) | none
	NoOpen bool       `json:"no_open,omitempty"`
}

type NewTaskResult struct {
	TaskID   string      `json:"task_id"`
	Branch   string      `json:"branch"`
	Path     string      `json:"path"`
	Base     string      `json:"base"`
	SetupCmd string      `json:"setup_cmd,omitempty"`
	Opened   *OpenResult `json:"opened,omitempty"`
}

// ResolveRepo accepts a repo path or its name relative to the roots.
func (service *Service) ResolveRepo(query string) (string, error) {
	if query == "" {
		return "", errors.New("repo is required")
	}
	expanded := canonical(config.Expand(query))
	if exists(filepath.Join(expanded, ".git")) {
		return expanded, nil
	}
	for _, root := range service.roots() {
		candidate := filepath.Join(root, query)
		if exists(filepath.Join(candidate, ".git")) {
			return canonical(candidate), nil
		}
	}
	return "", fmt.Errorf("repo %q not found under %v", query, service.Config.Roots)
}

// BaseRef resolves the start point for a new branch.
func (service *Service) BaseRef(repo string, from StartFrom, ref string) (string, error) {
	switch from {
	case "", FromBase:
		base := service.repoSettings(repo).BaseBranch
		if ref != "" {
			base = ref
		}
		resolved := service.Git.ResolveBase(repo, base)
		if resolved == "" {
			return "", fmt.Errorf("base branch %q not found locally or on origin", base)
		}
		return resolved, nil
	case FromLocal, FromRemote:
		if ref == "" {
			return "", errors.New("ref is required")
		}
		if _, err := service.Git.Run(repo, "rev-parse", "--verify", "--quiet", ref); err != nil {
			return "", fmt.Errorf("%s not found", ref)
		}
		return ref, nil
	case FromWorktree:
		if ref == "" {
			return "", errors.New("worktree path is required")
		}
		head, err := service.Git.Run(config.Expand(ref), "rev-parse", "HEAD")
		if err != nil {
			return "", err
		}
		return head, nil
	}
	return "", fmt.Errorf("unknown start point %q", from)
}

// NewTask creates a branch (in place or in a new worktree) and opens it with a fresh Claude session.
func (service *Service) NewTask(request NewTaskRequest, progress Progress) (NewTaskResult, error) {
	repo, err := service.ResolveRepo(request.Repo)
	if err != nil {
		return NewTaskResult{}, err
	}
	if err := service.Ops.ValidateBranchName(repo, request.Name); err != nil {
		return NewTaskResult{}, err
	}
	base, err := service.BaseRef(repo, request.From, request.Ref)
	if err != nil {
		return NewTaskResult{}, err
	}
	if request.From == "" || request.From == FromBase || request.From == FromRemote {
		progress.Step("Fetching origin")
		if err := service.Ops.Fetch(repo); err != nil {
			progress.Warn("Fetch failed (continuing with local refs): %v", err)
		}
	}
	result := NewTaskResult{TaskID: TaskID(repo, request.Name), Branch: request.Name, Base: base}
	switch request.Mode {
	case ModeInPlace:
		target := repo
		if request.Target != "" {
			target = config.Expand(request.Target)
		}
		progress.Step("Creating %s from %s in %s", request.Name, base, target)
		if err := service.Ops.CreateInPlace(target, request.Name, base, request.Stash); err != nil {
			return result, err
		}
		result.Path = target
	case "", ModeWorktree:
		path := gitops.WorktreePath(repo, request.Name)
		progress.Step("Creating worktree %s from %s", path, base)
		if err := service.Ops.AddWorktree(repo, path, request.Name, base, true); err != nil {
			return result, err
		}
		result.Path = path
		if request.Setup == nil || *request.Setup {
			result.SetupCmd = service.PrepareWorktree(repo, path, progress)
		}
	default:
		return result, fmt.Errorf("unknown mode %q", request.Mode)
	}
	if request.NoOpen {
		return result, nil
	}
	claudeCmd := "claude"
	if request.Open == OpenNone {
		claudeCmd = ""
	}
	progress.Step("Opening workspace")
	ticket := gitops.Ticket(request.Name)
	name := RepoLabel(repo) + " " + request.Name
	if ticket != "" {
		name = RepoLabel(repo) + " " + ticket
	}
	var existing *Workspace
	if request.Mode == ModeInPlace {
		existing = service.workspaceAt(result.Path)
	}
	opened, err := service.openAt(openTarget{
		name: name, cwd: result.Path, repo: repo, existing: existing,
		claudeCmd: claudeCmd, setupCmd: result.SetupCmd,
	})
	if err != nil {
		return result, err
	}
	result.Opened = &opened
	return result, nil
}

func (service *Service) workspaceAt(path string) *Workspace {
	workspaces, err := service.Cmux.Workspaces()
	if err != nil {
		return nil
	}
	for _, workspace := range workspaces {
		if canonical(workspace.Cwd) == canonical(path) {
			return &Workspace{ID: workspace.ID, Ref: workspace.Ref, Title: workspace.Title, Ports: workspace.Ports}
		}
	}
	return nil
}
