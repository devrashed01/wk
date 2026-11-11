package gitscan

import (
	"strings"
	"testing"

	"wk/internal/testutil"
)

func TestParseWorktreesMarksMainDetachedAndMissing(t *testing.T) {
	out := strings.Join([]string{
		"worktree /",
		"HEAD aaa",
		"branch refs/heads/production",
		"",
		"worktree /definitely/missing/path",
		"HEAD bbb",
		"detached",
		"prunable gitdir file points to non-existent location",
	}, "\n")
	worktrees := ParseWorktrees(out)
	if len(worktrees) != 2 {
		t.Fatalf("got %d worktrees", len(worktrees))
	}
	if !worktrees[0].Main || worktrees[0].Branch != "production" {
		t.Errorf("first = %+v", worktrees[0])
	}
	if !worktrees[1].Detached || !worktrees[1].Missing || worktrees[1].Main {
		t.Errorf("second = %+v", worktrees[1])
	}
}

func TestParseBranchesReadsTracking(t *testing.T) {
	out := "feature\x001700000000\x00origin/feature\x00[ahead 2, behind 1]\x00subject\n" +
		"old\x001600000000\x00origin/old\x00[gone]\x00bye"
	branches := ParseBranches(out)
	if branches[0].Ahead != 2 || branches[0].Behind != 1 || branches[0].Gone {
		t.Errorf("feature = %+v", branches[0])
	}
	if !branches[1].Gone {
		t.Errorf("old should be gone: %+v", branches[1])
	}
}

func TestMergedAndUnpushed(t *testing.T) {
	_, repo := testutil.Repo(t, "app")
	git := NewGit("")
	testutil.Git(t, repo, "switch", "-q", "-c", "merged-feature")
	testutil.Git(t, repo, "switch", "-q", "production")
	testutil.Git(t, repo, "switch", "-q", "-c", "local-work")
	testutil.Commit(t, repo, "a.txt", "local only")
	testutil.Git(t, repo, "switch", "-q", "production")

	merged := git.Merged(repo, "production")
	if !merged["merged-feature"] || merged["local-work"] {
		t.Errorf("merged = %v", merged)
	}
	if got := git.Unpushed(repo, "local-work"); got != 1 {
		t.Errorf("unpushed local-work = %d, want 1", got)
	}
	if got := git.Unpushed(repo, "merged-feature"); got != 0 {
		t.Errorf("unpushed merged-feature = %d, want 0", got)
	}
}

func TestFindReposSkipsWorktreesAndNodeModules(t *testing.T) {
	root, repo := testutil.Repo(t, "frontend/admin")
	testutil.Git(t, repo, "worktree", "add", "-q", "-b", "wt", repo+"-wt")
	repos := FindRepos([]string{root}, 3)
	if len(repos) != 1 || repos[0] != repo {
		t.Fatalf("repos = %v", repos)
	}
}

func TestDefaultBranchDetection(t *testing.T) {
	_, repo := testutil.Repo(t, "app") // has only "production"
	git := NewGit("")
	if got := git.DefaultBranch(repo); got != "production" {
		t.Errorf("without origin/HEAD = %q, want production", got)
	}
	testutil.Git(t, repo, "remote", "set-head", "origin", "production")
	testutil.Git(t, repo, "branch", "main")
	if got := git.DefaultBranch(repo); got != "production" {
		t.Errorf("origin/HEAD should win over a local main, got %q", got)
	}
}
