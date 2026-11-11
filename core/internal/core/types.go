// Package core assembles repos, tasks and sessions and performs every wk action.
// Both the CLI and the macOS app go through this package.
package core

import (
	"time"

	"wk/internal/gitscan"
)

// SessionState describes what a Claude session is doing right now.
type SessionState string

const (
	StateRunning SessionState = "running" // Claude is working
	StateWaiting SessionState = "waiting" // Claude process alive, turn finished: your move
	StateIdle    SessionState = "idle"    // no live process
	StateOrphan  SessionState = "orphan"  // its directory or branch no longer exists
)

type Repo struct {
	Path       string             `json:"path"`
	Name       string             `json:"name"`  // relative to its scan root, e.g. frontend/admin
	Label      string             `json:"label"` // short upper-case label, e.g. ADMIN
	BaseBranch string             `json:"base_branch"`
	ServerCmd  string             `json:"server_cmd,omitempty"`
	Worktrees  []gitscan.Worktree `json:"worktrees"`
	Error      string             `json:"error,omitempty"`
}

type Session struct {
	ID          string       `json:"id"`
	Title       string       `json:"title"`
	Alias       string       `json:"alias,omitempty"`
	FirstPrompt string       `json:"first_prompt,omitempty"`
	Cwd         string       `json:"cwd"`
	Branch      string       `json:"branch"`
	Branches    []string     `json:"branches"`
	Repo        string       `json:"repo,omitempty"` // repo path, when known
	TaskID      string       `json:"task_id,omitempty"`
	Start       time.Time    `json:"start"`
	Last        time.Time    `json:"last"`
	Prompts     int          `json:"prompts"`
	State       SessionState `json:"state"`
	Workspace   string       `json:"workspace,omitempty"` // cmux workspace id while live
	Surface     string       `json:"surface,omitempty"`
	CwdExists   bool         `json:"cwd_exists"`
	Size        int64        `json:"size,omitempty"` // transcript bytes on disk (resume re-reads this)
	Trashed     bool         `json:"trashed,omitempty"`
	Primary     bool         `json:"primary"` // false when shown on a task only because the session touched that branch
}

// DisplayTitle is the alias if set, else the transcript title.
func (session Session) DisplayTitle() string {
	if session.Alias != "" {
		return session.Alias
	}
	return session.Title
}

// Task is one (repo, branch) pair, checked out in a worktree or not.
type Task struct {
	ID           string     `json:"id"`
	Repo         string     `json:"repo"`
	RepoName     string     `json:"repo_name"`
	RepoLabel    string     `json:"repo_label"`
	Branch       string     `json:"branch"`
	Ticket       string     `json:"ticket,omitempty"`
	Path         string     `json:"path,omitempty"` // worktree path; empty when not checked out
	MainWorktree bool       `json:"main_worktree"`
	Detached     bool       `json:"detached"`
	Missing      bool       `json:"missing"` // worktree registered but directory gone
	IsBase       bool       `json:"is_base"`
	CommitDate   time.Time  `json:"commit_date"`
	Subject      string     `json:"subject,omitempty"`
	Upstream     string     `json:"upstream,omitempty"`
	Gone         bool       `json:"gone"`
	Merged       bool       `json:"merged"`
	Ahead        int        `json:"ahead"`
	Behind       int        `json:"behind"`
	Dirty        int        `json:"dirty"`
	Workspace    *Workspace `json:"workspace,omitempty"`
	Sessions     []Session  `json:"sessions"`
	Pinned       bool       `json:"pinned"`
	Hidden       bool       `json:"hidden"`
	Note         string     `json:"note,omitempty"`
	LastActivity time.Time  `json:"last_activity"`
	Running      int        `json:"running"`
	Waiting      int        `json:"waiting"`
	ParentID     string     `json:"parent_id,omitempty"` // env branch (-dev/-stg) folded under its feature task
	EnvBranches  []string   `json:"env_branches,omitempty"`
}

type Workspace struct {
	ID       string `json:"id"`
	Ref      string `json:"ref"`
	Title    string `json:"title"`
	Ports    []int  `json:"ports,omitempty"`
	Selected bool   `json:"selected"`
}

type Counts struct {
	Running int `json:"running"`
	Waiting int `json:"waiting"`
	Open    int `json:"open"`
	Tasks   int `json:"tasks"`
}

type Snapshot struct {
	GeneratedAt time.Time `json:"generated_at"`
	CmuxRunning bool      `json:"cmux_running"`
	Repos       []Repo    `json:"repos"`
	Tasks       []Task    `json:"tasks"`
	Sessions    []Session `json:"sessions"` // recent sessions (all are available via Sessions())
	Counts      Counts    `json:"counts"`
}
