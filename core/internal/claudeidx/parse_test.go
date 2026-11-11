package claudeidx

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseSummarizesTranscript(t *testing.T) {
	session, err := ParseFile("testdata/session.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "session" {
		t.Errorf("id = %q", session.ID)
	}
	if session.Cwd != "/repo" {
		t.Errorf("cwd = %q, sidechain cwd must be ignored", session.Cwd)
	}
	if got := strings.Join(session.Branches, ","); got != "production,ABC-4995-passport" {
		t.Errorf("branches = %q", got)
	}
	if session.LastBranch != "ABC-4995-passport" {
		t.Errorf("last branch = %q", session.LastBranch)
	}
	if session.FirstPrompt != "create new branch for ABC-4995" {
		t.Errorf("first prompt = %q, slash commands and tool results must be skipped", session.FirstPrompt)
	}
	if session.Prompts != 2 {
		t.Errorf("prompts = %d, want 2 typed prompts", session.Prompts)
	}
	if !session.EndedTurn {
		t.Error("expected ended turn after final assistant end_turn")
	}
	if want := time.Date(2026, 10, 20, 10, 1, 0, 0, time.UTC); !session.Last.Equal(want) {
		t.Errorf("last = %v", session.Last)
	}
}

func TestTitlePrefersCustomThenAIThenPrompt(t *testing.T) {
	cases := []struct {
		session Session
		want    string
	}{
		{Session{CustomTitle: "custom", AITitle: "ai", FirstPrompt: "prompt"}, "custom"},
		{Session{AITitle: "ai", FirstPrompt: "prompt"}, "ai"},
		{Session{FirstPrompt: "prompt"}, "prompt"},
		{Session{}, "(untitled)"},
	}
	for _, testCase := range cases {
		if got := testCase.session.Title(); got != testCase.want {
			t.Errorf("Title() = %q, want %q", got, testCase.want)
		}
	}
}

func TestSidecarTitleOverridesTranscript(t *testing.T) {
	dir := t.TempDir()
	data, _ := os.ReadFile("testdata/session.jsonl")
	path := filepath.Join(dir, "abc.jsonl")
	os.WriteFile(path, data, 0o644)
	os.MkdirAll(filepath.Join(dir, "abc"), 0o755)
	os.WriteFile(filepath.Join(dir, "abc", "custom-title.json"), []byte(`{"customTitle":"renamed later"}`), 0o644)
	session, err := ParseFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if session.Title() != "renamed later" {
		t.Errorf("title = %q", session.Title())
	}
}

func TestIncrementalUpdateParsesOnlyAppendedLines(t *testing.T) {
	dir := t.TempDir()
	projects := filepath.Join(dir, "projects", "-repo")
	os.MkdirAll(projects, 0o755)
	path := filepath.Join(projects, "s1.jsonl")
	first := `{"type":"user","cwd":"/repo","gitBranch":"a","timestamp":"2026-10-19T07:00:00Z","message":{"role":"user","content":"one"}}` + "\n"
	os.WriteFile(path, []byte(first), 0o644)

	index := LoadCache(filepath.Join(dir, "missing.json"))
	if _, err := index.Build(dir); err != nil {
		t.Fatal(err)
	}
	session := index.Sessions[path]
	if session.Prompts != 1 || session.Offset != int64(len(first)) {
		t.Fatalf("after first build prompts=%d offset=%d", session.Prompts, session.Offset)
	}

	partial := `{"type":"user","cwd":"/repo","gitBranch":"b","timestamp":"2026-10-19T08:00:00Z","message":{"role":"user","content":"two"}}`
	file, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	file.WriteString(partial[:40]) // half-written line must not be consumed
	file.Close()
	updated, changed, err := index.Update(path)
	if err != nil || !changed {
		t.Fatalf("update changed=%v err=%v", changed, err)
	}
	if updated.Prompts != 1 {
		t.Fatalf("partial line was parsed: prompts=%d", updated.Prompts)
	}

	file, _ = os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	file.WriteString(partial[40:] + "\n")
	file.Close()
	updated, _, _ = index.Update(path)
	if updated.Prompts != 2 || updated.LastBranch != "b" || updated.FirstPrompt != "one" {
		t.Fatalf("after append prompts=%d branch=%q first=%q", updated.Prompts, updated.LastBranch, updated.FirstPrompt)
	}
}

func TestCacheReusesUnchangedFiles(t *testing.T) {
	dir := t.TempDir()
	projects := filepath.Join(dir, "projects", "-repo")
	os.MkdirAll(projects, 0o755)
	os.WriteFile(filepath.Join(projects, "s1.jsonl"), []byte(`{"type":"user","cwd":"/repo","message":{"role":"user","content":"hi"}}`+"\n"), 0o644)
	cachePath := filepath.Join(dir, "cache.json")

	index := LoadCache(cachePath)
	stats, _ := index.Build(dir)
	if stats.Parsed != 1 {
		t.Fatalf("first build parsed %d", stats.Parsed)
	}
	if err := index.SaveCache(cachePath); err != nil {
		t.Fatal(err)
	}
	reloaded := LoadCache(cachePath)
	stats, _ = reloaded.Build(dir)
	if stats.Parsed != 0 || stats.Reused != 1 {
		t.Fatalf("second build parsed=%d reused=%d", stats.Parsed, stats.Reused)
	}
	if len(reloaded.List()) != 1 {
		t.Fatalf("list = %d", len(reloaded.List()))
	}
}
