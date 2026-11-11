// Package gitscan discovers repos, worktrees and branches and reads their status.
package gitscan

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Git runs git commands with a fixed binary.
type Git struct{ Bin string }

func NewGit(bin string) Git {
	if bin == "" {
		bin = FindBin("git", "/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git")
	}
	return Git{Bin: bin}
}

// FindBin looks up name on PATH, then falls back to known locations (GUI apps get a minimal PATH).
func FindBin(name string, fallbacks ...string) string {
	if path, err := exec.LookPath(name); err == nil {
		return path
	}
	for _, candidate := range fallbacks {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return name
}

// Run executes git in dir and returns trimmed stdout.
func (git Git) Run(dir string, args ...string) (string, error) {
	cmd := exec.Command(git.Bin, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), message)
	}
	return strings.TrimRight(stdout.String(), "\n"), nil
}

type Worktree struct {
	Path     string `json:"path"`
	Branch   string `json:"branch"` // empty when detached
	Head     string `json:"head"`
	Main     bool   `json:"main"`
	Missing  bool   `json:"missing"` // directory no longer exists (prunable)
	Locked   bool   `json:"locked"`
	Detached bool   `json:"detached"`
}

// Worktrees parses `git worktree list --porcelain` for a repo.
func (git Git) Worktrees(repo string) ([]Worktree, error) {
	out, err := git.Run(repo, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	return ParseWorktrees(out), nil
}

func ParseWorktrees(out string) []Worktree {
	var worktrees []Worktree
	for blockIndex, block := range strings.Split(strings.TrimSpace(out), "\n\n") {
		var worktree Worktree
		for _, line := range strings.Split(block, "\n") {
			key, value, _ := strings.Cut(line, " ")
			switch key {
			case "worktree":
				worktree.Path = value
			case "HEAD":
				worktree.Head = value
			case "branch":
				worktree.Branch = strings.TrimPrefix(value, "refs/heads/")
			case "detached":
				worktree.Detached = true
			case "prunable":
				worktree.Missing = true
			case "locked":
				worktree.Locked = true
			}
		}
		if worktree.Path == "" {
			continue
		}
		worktree.Main = blockIndex == 0
		if _, err := os.Stat(worktree.Path); err != nil {
			worktree.Missing = true
		}
		worktrees = append(worktrees, worktree)
	}
	return worktrees
}

type Branch struct {
	Name       string    `json:"name"`
	CommitDate time.Time `json:"commit_date"`
	Upstream   string    `json:"upstream,omitempty"`
	Gone       bool      `json:"gone"` // upstream configured but deleted on remote
	Ahead      int       `json:"ahead"`
	Behind     int       `json:"behind"`
	Subject    string    `json:"subject"`
}

const branchFormat = "%(refname:short)%00%(committerdate:unix)%00%(upstream:short)%00%(upstream:track)%00%(contents:subject)"

// Branches lists local branches, most recently committed first.
func (git Git) Branches(repo string) ([]Branch, error) {
	out, err := git.Run(repo, "for-each-ref", "refs/heads", "--sort=-committerdate", "--format="+branchFormat)
	if err != nil {
		return nil, err
	}
	return ParseBranches(out), nil
}

func ParseBranches(out string) []Branch {
	var branches []Branch
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Split(line, "\x00")
		if len(fields) < 5 || fields[0] == "" {
			continue
		}
		unix, _ := strconv.ParseInt(fields[1], 10, 64)
		branch := Branch{Name: fields[0], CommitDate: time.Unix(unix, 0), Upstream: fields[2], Subject: fields[4]}
		track := strings.Trim(fields[3], "[]")
		branch.Gone = track == "gone"
		for _, part := range strings.Split(track, ", ") {
			if count, ok := strings.CutPrefix(part, "ahead "); ok {
				branch.Ahead, _ = strconv.Atoi(count)
			}
			if count, ok := strings.CutPrefix(part, "behind "); ok {
				branch.Behind, _ = strconv.Atoi(count)
			}
		}
		branches = append(branches, branch)
	}
	return branches
}

// RemoteBranches lists remote-tracking branches (e.g. origin/feature), excluding HEAD.
func (git Git) RemoteBranches(repo string) ([]string, error) {
	out, err := git.Run(repo, "for-each-ref", "refs/remotes", "--sort=-committerdate", "--format=%(refname:short)")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, name := range strings.Split(out, "\n") {
		if name == "" || strings.HasSuffix(name, "/HEAD") || !strings.Contains(name, "/") {
			continue
		}
		names = append(names, name)
	}
	return names, nil
}

// ResolveBase returns base, or origin/base if only the remote ref exists.
func (git Git) ResolveBase(repo, base string) string {
	if _, err := git.Run(repo, "rev-parse", "--verify", "--quiet", "refs/heads/"+base); err == nil {
		return base
	}
	if _, err := git.Run(repo, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/"+base); err == nil {
		return "origin/" + base
	}
	return ""
}

// Merged returns the set of local branches fully merged into base.
func (git Git) Merged(repo, base string) map[string]bool {
	merged := map[string]bool{}
	ref := git.ResolveBase(repo, base)
	if ref == "" {
		return merged
	}
	out, err := git.Run(repo, "branch", "--merged", ref, "--format=%(refname:short)")
	if err != nil {
		return merged
	}
	for _, name := range strings.Split(out, "\n") {
		if name != "" && name != base {
			merged[name] = true
		}
	}
	return merged
}

type Status struct {
	Dirty     int      `json:"dirty"`      // number of changed/untracked paths
	Unpushed  int      `json:"unpushed"`   // commits not on any remote (or ahead of upstream)
	HasRemote bool     `json:"has_remote"` // origin/<branch> exists
	Changes   []string `json:"changes,omitempty"`
}

// WorktreeStatus inspects a checked-out worktree. path may be empty for a branch with no worktree.
func (git Git) WorktreeStatus(repo, path, branch string) Status {
	var status Status
	if path != "" {
		if out, err := git.Run(path, "status", "--porcelain"); err == nil && out != "" {
			status.Changes = strings.Split(out, "\n")
			status.Dirty = len(status.Changes)
		}
	}
	status.Unpushed = git.Unpushed(repo, branch)
	_, err := git.Run(repo, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/"+branch)
	status.HasRemote = err == nil
	return status
}

// Unpushed counts commits on branch that no remote-tracking ref contains.
func (git Git) Unpushed(repo, branch string) int {
	out, err := git.Run(repo, "rev-list", "--count", "refs/heads/"+branch, "--not", "--remotes")
	if err != nil {
		return 0
	}
	count, _ := strconv.Atoi(out)
	return count
}

// Log returns the last n commits as "hash subject (age)".
func (git Git) Log(dir, ref string, count int) []string {
	out, err := git.Run(dir, "log", "-n", strconv.Itoa(count), "--format=%h %s (%cr)", ref, "--")
	if err != nil || out == "" {
		return nil
	}
	return strings.Split(out, "\n")
}

// FindRepos walks roots (to maxDepth) and returns main repository paths (dirs with a .git directory).
func FindRepos(roots []string, maxDepth int) []string {
	var repos []string
	for _, root := range roots {
		walk(root, 0, maxDepth, &repos)
	}
	return repos
}

func walk(dir string, depth, maxDepth int, repos *[]string) {
	if info, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
		if info.IsDir() {
			*repos = append(*repos, dir)
		}
		return // a worktree (.git file) or repo: don't descend
	}
	if depth >= maxDepth {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || strings.HasPrefix(name, ".") || name == "node_modules" || name == "vendor" || name == "venv" {
			continue
		}
		walk(filepath.Join(dir, name), depth+1, maxDepth, repos)
	}
}

// DefaultBranch detects a repo's base branch: origin/HEAD, else main, master, production.
func (git Git) DefaultBranch(repo string) string {
	if out, err := git.Run(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"); err == nil && out != "" {
		return strings.TrimPrefix(out, "origin/")
	}
	for _, name := range []string{"main", "master", "production", "develop"} {
		if _, err := git.Run(repo, "rev-parse", "--verify", "--quiet", "refs/heads/"+name); err == nil {
			return name
		}
	}
	return "main"
}
