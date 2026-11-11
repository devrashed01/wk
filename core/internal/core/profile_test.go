package core

import (
	"os"
	"testing"
	"time"

	"wk/internal/cmux"
	"wk/internal/gitscan"
)

func TestProfileSnapshot(t *testing.T) {
	if os.Getenv("WK_PROFILE") == "" {
		t.Skip()
	}
	service, err := New()
	if err != nil {
		t.Fatal(err)
	}
	step := func(name string, fn func()) {
		started := time.Now()
		fn()
		t.Logf("%-14s %v", name, time.Since(started))
	}
	step("index", func() { service.RefreshIndex() })
	var repos []string
	step("findRepos", func() { repos = gitscan.FindRepos(service.roots(), maxRepoDepth) })
	step("scanRepos", func() { service.scanRepos() })
	for _, repo := range repos {
		step("  "+RepoLabel(repo), func() { service.scanRepo(repo) })
	}
	step("cmux", func() { service.Cmux.Workspaces() })
	step("agents", func() { cmux.AgentSessions() })
	step("snapshot", func() { service.Snapshot() })
	step("snapshot2", func() { service.Snapshot() })
}
