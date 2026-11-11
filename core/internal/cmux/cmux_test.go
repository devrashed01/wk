package cmux

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLayoutMatchesCmuxSchema(t *testing.T) {
	got := Layout("yarn dev", "claude --resume abc")
	want := `{"direction":"horizontal","split":0.6,"children":[` +
		`{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"claude --resume abc"}]}},` +
		`{"direction":"vertical","split":0.5,"children":[` +
		`{"pane":{"surfaces":[{"type":"terminal","name":"Server","command":"yarn dev"}]}},` +
		`{"pane":{"surfaces":[{"type":"terminal","name":"Git"}]}}]}]}`
	if got != want {
		t.Errorf("layout\n got  %s\n want %s", got, want)
	}
}

func TestParseAgentSessionsPrefersLiveRecord(t *testing.T) {
	data := []byte(`{"sessions":{
		"s1":{"sessionId":"abc","workspaceId":"W1","surfaceId":"S1","pid":1,"agentLifecycle":"idle"},
		"s2":{"sessionId":"abc","workspaceId":"W2","surfaceId":"S2","pid":2,"agentLifecycle":"running"}}}`)
	sessions := ParseAgentSessions(data, func(pid int) bool { return pid == 2 })
	session := sessions["abc"]
	if !session.Alive || session.WorkspaceID != "W2" || session.Lifecycle != "running" {
		t.Errorf("got %+v", session)
	}
}

func TestParseWorkspacesUsesCustomTitle(t *testing.T) {
	data := []byte(`{"workspaces":[{"id":"A","ref":"workspace:1","title":"zsh","custom_title":"ADMIN","current_directory":"/r/admin","listening_ports":[3000],"selected":true}]}`)
	workspaces, err := ParseWorkspaces(data)
	if err != nil {
		t.Fatal(err)
	}
	if workspaces[0].Title != "ADMIN" || workspaces[0].Cwd != "/r/admin" || workspaces[0].Ports[0] != 3000 {
		t.Errorf("got %+v", workspaces[0])
	}
}

func TestAccessDeniedIsReported(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "cmux")
	script := "#!/bin/sh\necho 'Error: ERROR: Access denied - only processes started inside cmux can connect' >&2\nexit 1\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := New(bin).Workspaces(); !errors.Is(err, ErrAccessDenied) {
		t.Fatalf("want ErrAccessDenied, got %v", err)
	}
}
