package core

import (
	"slices"
	"strings"
	"testing"

	"wk/internal/cmux"
	"wk/internal/jira"
	"wk/internal/prs"
)

func decorateFixture(workspace cmux.Workspace) (*Service, *fakeCmux) {
	fake := &fakeCmux{workspaces: []cmux.Workspace{workspace}}
	return &Service{Cmux: fake}, fake
}

func TestDecorateSendsNoteColorAndStatusOnce(t *testing.T) {
	service, fake := decorateFixture(cmux.Workspace{ID: "ws-1"})
	task := Task{RepoLabel: "WEB", Note: "waiting on API", Dirty: 2, Ahead: 1, Workspace: &Workspace{ID: "ws-1"}}
	service.DecorateCmux([]Task{task})
	want := []string{"ws-1|description|waiting on API", "ws-1|color|" + RepoColor("WEB"), "ws-1|wk.git|2 changed · ↑1", "ws-1|wk.jira|", "ws-1|wk.pr|"}
	if !slices.Equal(fake.decorations, want) {
		t.Fatalf("got %v, want %v", fake.decorations, want)
	}
	// cmux now reports what was set: nothing more to send.
	fake.workspaces[0].Description, fake.workspaces[0].Color = "waiting on API", strings.ToLower(RepoColor("WEB"))
	fake.decorations = nil
	service.DecorateCmux([]Task{task})
	if len(fake.decorations) != 0 {
		t.Fatalf("expected no calls, got %v", fake.decorations)
	}
	// Committing everything clears the pill.
	task.Dirty, task.Ahead = 0, 0
	service.DecorateCmux([]Task{task})
	if !slices.Equal(fake.decorations, []string{"ws-1|wk.git|"}) {
		t.Fatalf("got %v", fake.decorations)
	}
}

func TestDecorateKeepsUserDescriptionAndColor(t *testing.T) {
	service, fake := decorateFixture(cmux.Workspace{ID: "ws-1", Description: "my own text", Color: "Purple"})
	service.DecorateCmux([]Task{{RepoLabel: "WEB", Workspace: &Workspace{ID: "ws-1"}}})
	if !slices.Equal(fake.decorations, []string{"ws-1|wk.git|", "ws-1|wk.jira|", "ws-1|wk.pr|"}) {
		t.Fatalf("user's description or color was touched: %v", fake.decorations)
	}
}

func TestPlainCmuxRemovesWhatWkSet(t *testing.T) {
	service, fake := decorateFixture(cmux.Workspace{ID: "ws-1"})
	task := Task{RepoLabel: "WEB", Note: "n", Workspace: &Workspace{ID: "ws-1"}}
	service.DecorateCmux([]Task{task})
	fake.workspaces[0].Description, fake.workspaces[0].Color = "n", RepoColor("WEB")
	fake.decorations = nil
	service.Config.PlainCmux = true
	service.DecorateCmux([]Task{task})
	want := []string{"ws-1|description|", "ws-1|color|", "ws-1|wk.git|", "ws-1|wk.pr|", "ws-1|wk.jira|"}
	if !slices.Equal(fake.decorations, want) {
		t.Fatalf("got %v, want %v", fake.decorations, want)
	}
}

func TestGitStatus(t *testing.T) {
	cases := map[string]Task{
		"":                   {},
		"3 changed":          {Dirty: 3},
		"↑2 ↓1":              {Ahead: 2, Behind: 1},
		"merged":             {Merged: true},
		"remote branch gone": {Gone: true},
	}
	for want, task := range cases {
		if got := GitStatus(task).Value; got != want {
			t.Errorf("%+v: got %q, want %q", task, got, want)
		}
	}
}

func TestWithProgressReportsEachStep(t *testing.T) {
	got := withProgress("/bin/cmux", "yarn install && yarn build")
	want := `'/bin/cmux' set-progress 0.00 --label 'Setup 1/2 · yarn install' >/dev/null 2>&1 && yarn install && ` +
		`'/bin/cmux' set-progress 0.50 --label 'Setup 2/2 · yarn build' >/dev/null 2>&1 && yarn build && ` +
		`'/bin/cmux' clear-progress >/dev/null 2>&1`
	if got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
	if got := withProgress("/bin/cmux", ""); got != "" {
		t.Fatalf("empty setup should stay empty, got %q", got)
	}
	if got := withProgress("/bin/cmux", "a || b && c"); !strings.Contains(got, "Setup 1/1") {
		t.Fatalf("|| chains must stay one step: %s", got)
	}
}

func TestCloseWorkspaceClosesOnlyIdleWorkspaces(t *testing.T) {
	fx := newFixture(t)
	if _, err := fx.service.CloseWorkspace("production"); err == nil {
		t.Fatal("expected an error without a workspace")
	}
	fx.cmux.workspaces = []cmux.Workspace{{ID: "W1", Title: "ADMIN", Cwd: fx.repo}}
	message, err := fx.service.CloseWorkspace("production")
	if err != nil || !slices.Equal(fx.cmux.closed, []string{"W1"}) {
		t.Fatalf("message=%q err=%v closed=%v", message, err, fx.cmux.closed)
	}
}

func TestEnvPRsMatchByNameAndTicket(t *testing.T) {
	branches := map[string]prs.PR{
		"ABC-12-login":     {Number: 1},
		"ABC-12-stg":       {Number: 3},
		"ABC-12-login-dev": {Number: 2},
		"ABC-99-dev":       {Number: 9},
	}
	got := envPRs(Task{Branch: "ABC-12-login", Ticket: "ABC-12"}, branches)
	if len(got) != 2 || got[0].Env != "dev" || got[0].PR.Number != 2 || got[1].Env != "stg" || got[1].PR.Number != 3 {
		t.Fatalf("got %+v", got)
	}
}

func TestPRStatusPill(t *testing.T) {
	task := Task{
		PR:     &prs.PR{Number: 775, State: "draft", URL: "https://bitbucket.org/x/y/pull-requests/775"},
		EnvPRs: []EnvPR{{Env: "dev", PR: prs.PR{State: "open", Checks: "failing"}}, {Env: "stg", PR: prs.PR{State: "merged"}}},
	}
	pill := PRStatus(task)
	if pill.Value != "#775 draft · dev failing · stg merged" || pill.Color != "#E5484D" {
		t.Errorf("pill = %+v", pill)
	}
	if got := PRStatus(Task{PR: &prs.PR{Number: 1, State: "open", URL: "https://github.com/a/b/pull/1"}}); got.Value != "" {
		t.Errorf("a lone GitHub PR is cmux's own job, got %+v", got)
	}
}

func TestCleanupGroupsEnvBranchesUnderMergedFeature(t *testing.T) {
	items := []CleanupItem{
		{ID: "f", Kind: CleanupMerged, Branch: "ABC-1"},
		{ID: "d", Kind: CleanupMerged, Branch: "ABC-1-dev", parentID: "f", Dirty: 1},
		{ID: "s", Kind: CleanupStale, Branch: "ABC-1-stg", parentID: "f"},
		{ID: "o", Kind: CleanupGone, Branch: "ABC-2-dev", parentID: "unmerged"},
	}
	got := groupEnvBranches(items)
	if len(got) != 3 || got[0].ID != "f" || len(got[0].Includes) != 1 || got[0].Includes[0].Branch != "ABC-1-dev" || got[0].Dirty != 1 {
		t.Fatalf("got %+v", got)
	}
}

func TestDescriptionPutsTicketTitleAboveNote(t *testing.T) {
	task := Task{Note: "waiting on API", Issue: &jira.Issue{Key: "ABC-1", Summary: "Files tab", Status: "Blocked", Category: "indeterminate"}}
	if got := Description(task); got != "Files tab\nwaiting on API" {
		t.Errorf("description = %q", got)
	}
	if pill := JiraStatus(task); pill.Value != "ABC-1 · Blocked" || pill.Color != "#0090FF" {
		t.Errorf("pill = %+v", pill)
	}
}
