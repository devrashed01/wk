package gitops

import (
	"os"
	"path/filepath"
	"testing"

	"wk/internal/gitscan"
	"wk/internal/testutil"
)

func TestSlugAndTicket(t *testing.T) {
	cases := map[string]string{
		"ABC-5346-multi-hotel":      "ABC-5346-multi-hotel",
		"fix/ABC-5401-mobile":       "fix-ABC-5401-mobile",
		"feat/production/ABC-1 x y": "feat-production-ABC-1-x-y",
	}
	for branch, want := range cases {
		if got := Slug(branch); got != want {
			t.Errorf("Slug(%q) = %q, want %q", branch, got, want)
		}
	}
	if got := Ticket("fix/abc-5401-mobile"); got != "ABC-5401" {
		t.Errorf("Ticket = %q", got)
	}
	if got := Ticket("production-hotfixs"); got != "" {
		t.Errorf("Ticket = %q, want empty", got)
	}
	if got := WorktreePath("/r/frontend/admin", "fix/ABC-1"); got != "/r/frontend/admin-fix-ABC-1" {
		t.Errorf("WorktreePath = %q", got)
	}
}

func TestWorktreeLifecycle(t *testing.T) {
	_, repo := testutil.Repo(t, "admin")
	ops := Ops{Git: gitscan.NewGit("")}
	if err := ops.ValidateBranchName(repo, "bad..name"); err == nil {
		t.Error("expected invalid name error")
	}
	if err := ops.ValidateBranchName(repo, "production"); err == nil {
		t.Error("expected already-exists error")
	}
	path := WorktreePath(repo, "ABC-1-feature")
	if err := ops.AddWorktree(repo, path, "ABC-1-feature", "production", true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(path, "README.md")); err != nil {
		t.Fatal("worktree not checked out")
	}
	testutil.Write(t, path, "dirty.txt", "x")
	if err := ops.RemoveWorktree(repo, path, false); err == nil {
		t.Error("non-force removal of a dirty worktree must fail")
	}
	if err := ops.RemoveWorktree(repo, path, true); err != nil {
		t.Fatal(err)
	}
	if err := ops.RenameBranch(repo, "ABC-1-feature", "ABC-1-renamed"); err != nil {
		t.Fatal(err)
	}
	if err := ops.DeleteBranch(repo, "ABC-1-renamed", false); err != nil {
		t.Fatal(err)
	}
}

func TestSwitchRefusesDirtyTreeUnlessStashed(t *testing.T) {
	_, repo := testutil.Repo(t, "admin")
	ops := Ops{Git: gitscan.NewGit("")}
	testutil.Git(t, repo, "branch", "other")
	testutil.Write(t, repo, "README.md", "changed\n")
	if err := ops.Switch(repo, "other", false); err == nil {
		t.Fatal("expected dirty error")
	}
	if err := ops.Switch(repo, "other", true); err != nil {
		t.Fatal(err)
	}
	if out := testutil.Git(t, repo, "stash", "list"); out == "" {
		t.Error("expected an auto-stash entry")
	}
}

func TestSwitchToRemoteBranchCreatesTrackingBranch(t *testing.T) {
	_, repo := testutil.Repo(t, "admin")
	ops := Ops{Git: gitscan.NewGit("")}
	testutil.Git(t, repo, "push", "-q", "origin", "production:remote-only")
	testutil.Git(t, repo, "fetch", "-q")
	if err := ops.Switch(repo, "origin/remote-only", false); err != nil {
		t.Fatal(err)
	}
	if got := testutil.Git(t, repo, "branch", "--show-current"); got != "remote-only\n" {
		t.Errorf("current = %q", got)
	}
}
