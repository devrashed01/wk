// Package gitops performs branch and worktree mutations.
package gitops

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"wk/internal/gitscan"
)

type Ops struct{ Git gitscan.Git }

var slugUnsafe = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// Slug turns a branch name into a directory-safe suffix ("feat/ABC-1 x" -> "feat-ABC-1-x").
func Slug(branch string) string {
	slug := slugUnsafe.ReplaceAllString(strings.ReplaceAll(branch, "/", "-"), "-")
	return strings.Trim(slug, "-.")
}

var ticketPattern = regexp.MustCompile(`(?i)\b([A-Z][A-Z0-9]+-\d+)`)

// Ticket extracts a Jira-style key (ABC-1234) from a branch name.
func Ticket(branch string) string {
	match := ticketPattern.FindStringSubmatch(branch)
	if match == nil {
		return ""
	}
	return strings.ToUpper(match[1])
}

// WorktreePath is the sibling directory convention: <repo>-<slug>.
func WorktreePath(repo, branch string) string {
	return filepath.Join(filepath.Dir(repo), filepath.Base(repo)+"-"+Slug(branch))
}

// ValidateBranchName checks the name with git check-ref-format and that it is unused.
func (ops Ops) ValidateBranchName(repo, name string) error {
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("branch name is empty")
	}
	if _, err := ops.Git.Run(repo, "check-ref-format", "--branch", name); err != nil {
		return fmt.Errorf("%q is not a valid branch name", name)
	}
	if ops.BranchExists(repo, name) {
		return fmt.Errorf("branch %q already exists", name)
	}
	return nil
}

func (ops Ops) BranchExists(repo, name string) bool {
	_, err := ops.Git.Run(repo, "rev-parse", "--verify", "--quiet", "refs/heads/"+name)
	return err == nil
}

// CreateInPlace creates and switches to a new branch in an existing worktree.
func (ops Ops) CreateInPlace(worktree, name, base string, stash bool) error {
	if err := ops.ensureClean(worktree, stash); err != nil {
		return err
	}
	_, err := ops.Git.Run(worktree, "switch", "-c", name, base)
	return err
}

// Switch checks out an existing local branch, or a remote branch (origin/x) as a tracking branch.
func (ops Ops) Switch(worktree, branch string, stash bool) error {
	if err := ops.ensureClean(worktree, stash); err != nil {
		return err
	}
	if remote, local, ok := splitRemote(branch); ok && !ops.BranchExists(worktree, local) {
		_, err := ops.Git.Run(worktree, "switch", "-c", local, "--track", remote)
		return err
	}
	_, err := ops.Git.Run(worktree, "switch", branch)
	return err
}

// AddWorktree creates a worktree at path. With newBranch it creates the branch from base;
// otherwise it checks out an existing local branch, or tracks a remote one (origin/x).
func (ops Ops) AddWorktree(repo, path, branch, base string, newBranch bool) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("%s already exists", path)
	}
	switch {
	case newBranch:
		_, err := ops.Git.Run(repo, "worktree", "add", "-b", branch, path, base)
		return err
	default:
		if remote, local, ok := splitRemote(branch); ok && !ops.BranchExists(repo, local) {
			_, err := ops.Git.Run(repo, "worktree", "add", "--track", "-b", local, path, remote)
			return err
		}
		_, err := ops.Git.Run(repo, "worktree", "add", path, branch)
		return err
	}
}

// RemoveWorktree removes a worktree directory; force discards uncommitted changes.
func (ops Ops) RemoveWorktree(repo, path string, force bool) error {
	args := []string{"worktree", "remove", path}
	if force {
		args = []string{"worktree", "remove", "--force", path}
	}
	if _, err := ops.Git.Run(repo, args...); err != nil {
		if _, statErr := os.Stat(path); os.IsNotExist(statErr) {
			_, err = ops.Git.Run(repo, "worktree", "prune")
		}
		return err
	}
	return nil
}

func (ops Ops) Prune(repo string) error {
	_, err := ops.Git.Run(repo, "worktree", "prune")
	return err
}

// DeleteBranch deletes a local branch; force allows unmerged branches.
func (ops Ops) DeleteBranch(repo, branch string, force bool) error {
	flag := "-d"
	if force {
		flag = "-D"
	}
	_, err := ops.Git.Run(repo, "branch", flag, branch)
	return err
}

func (ops Ops) DeleteRemoteBranch(repo, branch string) error {
	_, err := ops.Git.Run(repo, "push", "origin", "--delete", branch)
	return err
}

func (ops Ops) RenameBranch(repo, oldName, newName string) error {
	if err := ops.ValidateBranchName(repo, newName); err != nil {
		return err
	}
	_, err := ops.Git.Run(repo, "branch", "-m", oldName, newName)
	return err
}

// Pull fetches and fast-forwards the worktree's current branch.
func (ops Ops) Pull(worktree string) (string, error) {
	return ops.Git.Run(worktree, "pull", "--ff-only")
}

func (ops Ops) Fetch(repo string) error {
	_, err := ops.Git.Run(repo, "fetch", "--prune")
	return err
}

func (ops Ops) ensureClean(worktree string, stash bool) error {
	out, err := ops.Git.Run(worktree, "status", "--porcelain")
	if err != nil {
		return err
	}
	if out == "" {
		return nil
	}
	if !stash {
		return fmt.Errorf("worktree has uncommitted changes (%d paths); commit, stash, or pass --stash", len(strings.Split(out, "\n")))
	}
	_, err = ops.Git.Run(worktree, "stash", "push", "--include-untracked", "-m", "wk: auto-stash before switch")
	return err
}

func splitRemote(branch string) (remote, local string, ok bool) {
	prefix, rest, found := strings.Cut(branch, "/")
	if !found || prefix != "origin" {
		return "", "", false
	}
	return branch, rest, true
}
