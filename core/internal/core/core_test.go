package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"wk/internal/claudeidx"
	"wk/internal/cmux"
	"wk/internal/config"
	"wk/internal/gitops"
	"wk/internal/gitscan"
	"wk/internal/state"
	"wk/internal/testutil"
)

type fakeCmux struct {
	workspaces []cmux.Workspace
	created    []string // name|cwd|layout|command
	selected   []string
	closed     []string
	surfaces   []string
	missing    bool // cmux not installed (and so not running)
}

func (fake *fakeCmux) Workspaces() ([]cmux.Workspace, error) {
	if fake.missing {
		return nil, errors.New("not running")
	}
	return fake.workspaces, nil
}
func (fake *fakeCmux) Installed() bool                   { return !fake.missing }
func (fake *fakeCmux) Select(id string) error            { fake.selected = append(fake.selected, id); return nil }
func (fake *fakeCmux) Close(id string) error             { fake.closed = append(fake.closed, id); return nil }
func (fake *fakeCmux) Activate()                         {}
func (fake *fakeCmux) FocusSurface(string, string) error { return nil }
func (fake *fakeCmux) NewSurface(workspace, command string) error {
	fake.surfaces = append(fake.surfaces, workspace+"|"+command)
	return nil
}
func (fake *fakeCmux) CreateWorkspace(name, cwd, command, layout string) (string, error) {
	fake.created = append(fake.created, name+"|"+cwd+"|"+layout+"|"+command)
	return "workspace:9", nil
}

type fixture struct {
	service *Service
	cmux    *fakeCmux
	root    string
	repo    string
	claude  string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root, repo := testutil.Repo(t, "frontend/admin")
	root, repo = canonical(root), canonical(repo)
	base := filepath.Dir(root)
	t.Setenv("WK_STATE_DIR", filepath.Join(base, "state"))
	t.Setenv("WK_CACHE_DIR", filepath.Join(base, "cache"))
	t.Setenv("WK_CONFIG", filepath.Join(base, "config.toml"))
	t.Setenv("WK_CMUX_HOOK_SESSIONS", filepath.Join(base, "hooks.json"))
	t.Setenv("CMUX_WORKSPACE_ID", "")
	claude := filepath.Join(base, "claude")
	cfg := config.Defaults()
	cfg.Roots = []string{root}
	cfg.ClaudeDir = claude
	st, _ := state.Load()
	git := gitscan.NewGit("")
	fake := &fakeCmux{}
	return &fixture{
		service: &Service{Config: cfg, State: st, Index: claudeidx.LoadCache(filepath.Join(base, "none.json")),
			Git: git, Ops: gitops.Ops{Git: git}, Cmux: fake},
		cmux: fake, root: root, repo: repo, claude: claude,
	}
}

// addSession writes a transcript with one prompt per branch, in order.
func (fx *fixture) addSession(t *testing.T, id, cwd string, branches ...string) {
	t.Helper()
	dir := filepath.Join(fx.claude, "projects", strings.ReplaceAll(cwd, "/", "-"))
	os.MkdirAll(dir, 0o755)
	var lines []string
	for index, branch := range branches {
		line, _ := json.Marshal(map[string]any{
			"type": "user", "cwd": cwd, "gitBranch": branch,
			"timestamp": fmt.Sprintf("2026-11-0%dT10:00:00Z", index+1),
			"message":   map[string]any{"role": "user", "content": "work on " + branch},
		})
		lines = append(lines, string(line))
	}
	os.WriteFile(filepath.Join(dir, id+".jsonl"), []byte(strings.Join(lines, "\n")+"\n"), 0o644)
}

func (fx *fixture) snapshot(t *testing.T) Snapshot {
	t.Helper()
	snapshot, err := fx.service.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func findTask(t *testing.T, snapshot Snapshot, branch string) Task {
	t.Helper()
	for _, task := range snapshot.Tasks {
		if task.Branch == branch {
			return task
		}
	}
	t.Fatalf("no task for %s", branch)
	return Task{}
}

func TestSnapshotLinksSessionsToTheirBranchTask(t *testing.T) {
	fx := newFixture(t)
	testutil.Git(t, fx.repo, "switch", "-q", "-c", "ABC-1-feature")
	testutil.Commit(t, fx.repo, "f.txt", "feature work")
	fx.addSession(t, "sess-1", fx.repo, "production", "ABC-1-feature")

	snapshot := fx.snapshot(t)
	task := findTask(t, snapshot, "ABC-1-feature")
	if task.Path != fx.repo || !task.MainWorktree || task.Ticket != "ABC-1" {
		t.Errorf("task = %+v", task)
	}
	if len(task.Sessions) != 1 || !task.Sessions[0].Primary || task.Sessions[0].Title != "work on production" {
		t.Errorf("sessions = %+v", task.Sessions)
	}
	for _, other := range snapshot.Tasks {
		if other.Branch == "production" {
			t.Error("base branch must not be a separate task when not checked out")
		}
	}
}

func TestEnvBranchesFoldUnderFeature(t *testing.T) {
	fx := newFixture(t)
	testutil.Git(t, fx.repo, "branch", "ABC-2-thing")
	testutil.Git(t, fx.repo, "branch", "ABC-2-dev")
	testutil.Git(t, fx.repo, "branch", "ABC-2-stg")
	fx.addSession(t, "cherry", fx.repo, "ABC-2-dev")

	snapshot := fx.snapshot(t)
	feature := findTask(t, snapshot, "ABC-2-thing")
	if strings.Join(feature.EnvBranches, ",") != "ABC-2-dev,ABC-2-stg" && strings.Join(feature.EnvBranches, ",") != "ABC-2-stg,ABC-2-dev" {
		t.Errorf("env branches = %v", feature.EnvBranches)
	}
	if len(feature.Sessions) != 1 || feature.Sessions[0].ID != "cherry" {
		t.Errorf("env session not merged into feature: %+v", feature.Sessions)
	}
	if dev := findTask(t, snapshot, "ABC-2-dev"); dev.ParentID != feature.ID {
		t.Errorf("dev parent = %q", dev.ParentID)
	}
}

func TestOpenStagesResumeAndSinglePane(t *testing.T) {
	t.Setenv("SHELL", "/bin/zsh")
	fx := newFixture(t)
	fx.addSession(t, "sess-a", fx.repo, "production")
	fx.service.Config.Repos = map[string]config.Repo{config.Collapse(fx.repo): {ServerCmd: "yarn dev"}}

	if _, err := fx.service.Open(OpenRequest{Task: "production", Single: true}, NopProgress{}); err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(fx.cmux.created[0], "|")
	if layout, command := parts[2], parts[3]; layout != "" || command != "print -z 'claude --resume sess-a'" {
		t.Errorf("single open: layout = %q command = %q", layout, command)
	}
	if _, err := fx.service.Open(OpenRequest{Task: "production", Mode: OpenNew, Single: true}, NopProgress{}); err != nil {
		t.Fatal(err)
	}
	if command := strings.Split(fx.cmux.created[1], "|")[3]; command != "print -z 'claude'" {
		t.Errorf("fresh session should be staged too, command = %q", command)
	}

	fx.service.Config.AutoStartClaude = true
	if _, err := fx.service.Open(OpenRequest{Task: "production", Single: true}, NopProgress{}); err != nil {
		t.Fatal(err)
	}
	if command := strings.Split(fx.cmux.created[2], "|")[3]; command != "claude --resume sess-a" {
		t.Errorf("auto_start_claude should run the command, got %q", command)
	}
	if _, err := fx.service.Open(OpenRequest{Task: "production", Mode: OpenNew, Single: true}, NopProgress{}); err != nil {
		t.Fatal(err)
	}
	if command := strings.Split(fx.cmux.created[3], "|")[3]; command != "claude" {
		t.Errorf("auto_start_claude should start a fresh session, got %q", command)
	}

	t.Setenv("SHELL", "/bin/bash")
	if got := stageClaude("claude --resume x"); got != "claude --resume x" {
		t.Errorf("non-zsh shells cannot stage, got %q", got)
	}
}

func TestOpenSelectsExistingWorkspaceOrCreatesLayout(t *testing.T) {
	fx := newFixture(t)
	fx.addSession(t, "sess-a", fx.repo, "production")
	fx.service.Config.Repos = map[string]config.Repo{config.Collapse(fx.repo): {ServerCmd: "yarn dev"}}

	result, err := fx.service.Open(OpenRequest{Task: "production"}, NopProgress{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Action != "created" || len(fx.cmux.created) != 1 {
		t.Fatalf("result = %+v created = %v", result, fx.cmux.created)
	}
	if !strings.Contains(fx.cmux.created[0], "claude --resume sess-a") || !strings.Contains(fx.cmux.created[0], "yarn dev") {
		t.Errorf("layout = %s", fx.cmux.created[0])
	}

	fx.cmux.workspaces = []cmux.Workspace{{ID: "W1", Title: "ADMIN", Cwd: fx.repo}}
	result, err = fx.service.Open(OpenRequest{Task: "production", Mode: OpenNone}, NopProgress{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Action != "selected" || fx.cmux.selected[0] != "W1" {
		t.Errorf("result = %+v selected = %v", result, fx.cmux.selected)
	}
}

func TestOpenBranchWithoutFolderNeedsCheckoutChoice(t *testing.T) {
	fx := newFixture(t)
	testutil.Git(t, fx.repo, "branch", "ABC-3-elsewhere")
	if _, err := fx.service.Open(OpenRequest{Task: "ABC-3"}, NopProgress{}); err != ErrNeedsCheckout {
		t.Fatalf("err = %v, want ErrNeedsCheckout", err)
	}
	result, err := fx.service.Open(OpenRequest{Task: "ABC-3", Via: ViaWorktree, Mode: OpenNone}, NopProgress{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Cwd != fx.repo+"-ABC-3-elsewhere" {
		t.Errorf("cwd = %s", result.Cwd)
	}
}

func TestNewTaskCreatesWorktreeAndCopiesEnv(t *testing.T) {
	t.Setenv("SHELL", "/bin/zsh")
	fx := newFixture(t)
	testutil.Write(t, fx.repo, ".env.local", "SECRET=1\n")
	testutil.Write(t, fx.repo, "yarn.lock", "")
	testutil.Git(t, fx.repo, "add", "yarn.lock")
	testutil.Git(t, fx.repo, "commit", "-q", "-m", "lock")
	result, err := fx.service.NewTask(NewTaskRequest{Repo: "frontend/admin", Name: "ABC-9-new"}, NopProgress{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Path != fx.repo+"-ABC-9-new" || result.SetupCmd != "yarn install" {
		t.Errorf("result = %+v", result)
	}
	if _, err := os.Stat(filepath.Join(result.Path, ".env.local")); err != nil {
		t.Error(".env.local was not copied")
	}
	if len(fx.cmux.created) != 1 || !strings.HasPrefix(fx.cmux.created[0], "ADMIN ABC-9|") || !strings.Contains(fx.cmux.created[0], "yarn install") {
		t.Errorf("created = %v", fx.cmux.created)
	}
	if !strings.Contains(fx.cmux.created[0], "print -z 'claude'") {
		t.Errorf("new task should only type claude at the prompt: %s", fx.cmux.created[0])
	}
}

func TestRemoveRequiresConfirmWhenWorkWouldBeLost(t *testing.T) {
	fx := newFixture(t)
	path := fx.repo + "-ABC-4-x"
	testutil.Git(t, fx.repo, "worktree", "add", "-q", "-b", "ABC-4-x", path)
	testutil.Commit(t, path, "x.txt", "unpushed work")
	testutil.Write(t, path, "dirty.txt", "uncommitted")

	plan, err := fx.service.PlanRemove("ABC-4")
	if err != nil {
		t.Fatal(err)
	}
	if !plan.RequiresConfirm || plan.Facts.Unpushed != 1 || plan.Facts.Dirty != 1 {
		t.Fatalf("plan facts = %+v confirm=%v", plan.Facts, plan.RequiresConfirm)
	}
	if plan.Options[OptRemoveWorktree].Default || plan.Options[OptDeleteBranch].Default {
		t.Fatalf("steps that lose work must not be pre-ticked: %+v", plan.Options)
	}
	everything := map[string]bool{OptRemoveWorktree: true, OptDeleteBranch: true}
	if _, err := fx.service.ApplyRemove(RemoveRequest{Task: "ABC-4", Options: everything}, NopProgress{}); err == nil {
		t.Fatal("expected confirmation error")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("worktree removed without confirmation")
	}
	results, err := fx.service.ApplyRemove(RemoveRequest{Task: "ABC-4", Options: everything, Confirm: "ABC-4-x"}, NopProgress{})
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range results {
		if !step.OK {
			t.Errorf("step failed: %+v", step)
		}
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("worktree still exists")
	}
	if fx.service.Ops.BranchExists(fx.repo, "ABC-4-x") {
		t.Error("branch still exists")
	}
}

func TestRemoveNeverDeletesMainFolderOrBaseBranch(t *testing.T) {
	fx := newFixture(t)
	plan, err := fx.service.PlanRemove("production")
	if err != nil {
		t.Fatal(err)
	}
	if plan.Options[OptRemoveWorktree].Available || plan.Options[OptDeleteBranch].Available {
		t.Errorf("options = %+v", plan.Options)
	}
}

func TestRemoveBranchInMainFolderSwitchesToBaseFirst(t *testing.T) {
	fx := newFixture(t)
	testutil.Git(t, fx.repo, "switch", "-q", "-c", "ABC-5-main")
	plan, _ := fx.service.PlanRemove("ABC-5")
	if !plan.Options[OptSwitchMainToBase].Default {
		t.Fatalf("switch option = %+v", plan.Options[OptSwitchMainToBase])
	}
	if _, err := fx.service.ApplyRemove(RemoveRequest{Task: "ABC-5"}, NopProgress{}); err != nil {
		t.Fatal(err)
	}
	if current := strings.TrimSpace(testutil.Git(t, fx.repo, "branch", "--show-current")); current != "production" {
		t.Errorf("main folder on %s", current)
	}
	if fx.service.Ops.BranchExists(fx.repo, "ABC-5-main") {
		t.Error("branch still exists")
	}
}

func TestTrashAndRestoreSession(t *testing.T) {
	fx := newFixture(t)
	fx.addSession(t, "to-trash", fx.repo, "production")
	fx.snapshot(t)
	if err := fx.service.TrashSession("to-trash"); err != nil {
		t.Fatal(err)
	}
	if sessions, _ := fx.service.Sessions("", false); len(sessions) != 0 {
		t.Fatalf("still listed: %+v", sessions)
	}
	trashed, _ := fx.service.Sessions("", true)
	if len(trashed) != 1 || !trashed[0].Trashed {
		t.Fatalf("trash listing = %+v", trashed)
	}
	if err := fx.service.RestoreSession("to-trash"); err != nil {
		t.Fatal(err)
	}
	if sessions, _ := fx.service.Sessions("", false); len(sessions) != 1 {
		t.Fatalf("not restored: %+v", sessions)
	}
}

func TestCleanupFindsMergedAndOrphans(t *testing.T) {
	fx := newFixture(t)
	testutil.Git(t, fx.repo, "branch", "ABC-6-done")
	fx.addSession(t, "orphan", filepath.Join(filepath.Dir(fx.repo), "admin-deleted"), "ABC-7-gone")
	items, err := fx.service.Cleanup()
	if err != nil {
		t.Fatal(err)
	}
	kinds := map[CleanupKind]bool{}
	for _, item := range items {
		kinds[item.Kind] = true
	}
	if !kinds[CleanupMerged] || !kinds[CleanupOrphanSession] {
		t.Errorf("items = %+v", items)
	}
	results, err := fx.service.ApplyCleanup([]string{TaskID(fx.repo, "ABC-6-done")}, false, NopProgress{})
	if err != nil || len(results) == 0 {
		t.Fatalf("results=%v err=%v", results, err)
	}
	if fx.service.Ops.BranchExists(fx.repo, "ABC-6-done") {
		t.Error("merged branch not deleted")
	}
}

func TestFindTaskByTicketNumber(t *testing.T) {
	tasks := []Task{{ID: "a#ABC-5346-x", Ticket: "ABC-5346", Branch: "ABC-5346-x"}, {ID: "a#ABC-12-y", Ticket: "ABC-12", Branch: "ABC-12-y"}}
	task, err := FindTask(tasks, "5346")
	if err != nil || task.Ticket != "ABC-5346" {
		t.Fatalf("task=%+v err=%v", task, err)
	}
	if _, err := FindTask(tasks, "VAY"); err == nil {
		t.Error("expected ambiguity error")
	}
}

func TestPaneSpecsPlaceSetupOnce(t *testing.T) {
	layout := config.Layout{Panes: []config.Pane{{Kind: "claude"}, {Kind: "command", Command: "lazygit"}, {Kind: "shell", Name: "Scratch"}}}
	specs := paneSpecs(layout, "claude", "yarn install", "yarn dev")
	if specs[0].Command != "claude" || specs[1].Name != "lazygit" || specs[1].Command != "lazygit" || specs[2].Command != "yarn install" {
		t.Errorf("no server pane: setup should run in the first shell: %+v", specs)
	}
	layout.Panes = append(layout.Panes, config.Pane{Kind: "server"}, config.Pane{Kind: "setup"})
	specs = paneSpecs(layout, "claude", "yarn install", "yarn dev")
	if specs[3].Command != "yarn dev" || specs[4].Command != "yarn install" || specs[4].Name != "Setup" || specs[2].Command != "" {
		t.Errorf("setup pane should take the install: %+v", specs)
	}
	only := paneSpecs(config.Layout{Panes: []config.Pane{{Kind: "claude"}}}, "claude", "yarn install", "")
	if only[0].Command != "yarn install && claude" {
		t.Errorf("single pane: %+v", only)
	}
}

func TestOpenUsesConfiguredLayout(t *testing.T) {
	fx := newFixture(t)
	fx.service.Config.Layout = &config.Layout{Arrange: "tabs", Panes: []config.Pane{{Kind: "claude"}, {Kind: "shell"}}}
	fx.service.Config.AutoStartClaude = true
	snapshot := fx.snapshot(t)
	if _, err := fx.service.Open(OpenRequest{Task: findTask(t, snapshot, "production").ID, Mode: OpenNew}, NopProgress{}); err != nil {
		t.Fatal(err)
	}
	want := `{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"claude"},{"type":"terminal","name":"Terminal"}]}}`
	if !strings.Contains(fx.cmux.created[0], want) {
		t.Errorf("layout = %s", fx.cmux.created[0])
	}
}

func TestOpenWithoutCmuxFallsBackImmediately(t *testing.T) {
	fixture := newFixture(t)
	fixture.cmux.missing = true
	start := time.Now()
	result, err := fixture.service.Open(OpenRequest{Task: "production"}, NopProgress{})
	if err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("waited %s for a cmux that isn't installed", time.Since(start))
	}
	if result.Action != "printed" || !strings.Contains(result.Command, "cd ") || !strings.Contains(result.Message, "not installed") {
		t.Fatalf("unexpected result %+v", result)
	}
}

func TestPushBranchPublishesUnpushedWork(t *testing.T) {
	fx := newFixture(t)
	testutil.Git(t, fx.repo, "switch", "-q", "-c", "ABC-9-push")
	testutil.Commit(t, fx.repo, "p.txt", "unpushed")
	if _, err := fx.service.PushBranch(fx.repo, "ABC-9-push"); err != nil {
		t.Fatal(err)
	}
	if out := testutil.Git(t, fx.repo, "ls-remote", "--heads", "origin", "ABC-9-push"); !strings.Contains(out, "ABC-9-push") {
		t.Fatalf("branch not on origin: %q", out)
	}
}
