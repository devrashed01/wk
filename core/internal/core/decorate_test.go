package core

import (
	"slices"
	"strings"
	"testing"

	"wk/internal/cmux"
)

func decorateFixture(workspace cmux.Workspace) (*Service, *fakeCmux) {
	fake := &fakeCmux{workspaces: []cmux.Workspace{workspace}}
	return &Service{Cmux: fake}, fake
}

func TestDecorateSendsNoteColorAndStatusOnce(t *testing.T) {
	service, fake := decorateFixture(cmux.Workspace{ID: "ws-1"})
	task := Task{RepoLabel: "WEB", Note: "waiting on API", Dirty: 2, Ahead: 1, Workspace: &Workspace{ID: "ws-1"}}
	service.DecorateCmux([]Task{task})
	want := []string{"ws-1|description|waiting on API", "ws-1|color|" + RepoColor("WEB"), "ws-1|status|2 changed · ↑1"}
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
	if !slices.Equal(fake.decorations, []string{"ws-1|status|"}) {
		t.Fatalf("got %v", fake.decorations)
	}
}

func TestDecorateKeepsUserDescriptionAndColor(t *testing.T) {
	service, fake := decorateFixture(cmux.Workspace{ID: "ws-1", Description: "my own text", Color: "Purple"})
	service.DecorateCmux([]Task{{RepoLabel: "WEB", Workspace: &Workspace{ID: "ws-1"}}})
	if !slices.Equal(fake.decorations, []string{"ws-1|status|"}) {
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
	want := []string{"ws-1|description|", "ws-1|color|", "ws-1|status|"}
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
