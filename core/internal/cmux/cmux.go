// Package cmux wraps the cmux CLI and its Claude hook-session state file.
package cmux

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"wk/internal/config"
	"wk/internal/gitscan"
)

type Client struct{ Bin string }

// ErrAccessDenied means cmux is running but its socket only accepts processes started inside cmux
// (the default "cmuxOnly" mode), so an app launched outside cmux, like Wk.app, cannot control it.
var ErrAccessDenied = errors.New(`cmux blocked wk: it only accepts processes started inside cmux. ` +
	`In cmux Settings → Automation, set socket control to "Automation mode" ` +
	`(or add "automation": {"socketControlMode": "automation"} to ~/.config/cmux/cmux.json and run "cmux reload-config")`)

func New(bin string) Client {
	if bin == "" {
		bin = gitscan.FindBin("cmux", "/Applications/cmux.app/Contents/Resources/bin/cmux")
	}
	return Client{Bin: bin}
}

func (client Client) run(args ...string) ([]byte, error) {
	cmd := exec.Command(client.Bin, args...)
	cmd.Env = append(os.Environ(), "CMUX_QUIET=1")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if strings.Contains(message, "Access denied") {
			return nil, ErrAccessDenied
		}
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf("cmux %s: %s", args[0], message)
	}
	return stdout.Bytes(), nil
}

type Workspace struct {
	ID       string `json:"id"`
	Ref      string `json:"ref"`
	Title    string `json:"title"`
	Cwd      string `json:"cwd"`
	Ports    []int  `json:"ports,omitempty"`
	Selected bool   `json:"selected"`
}

type rawWorkspace struct {
	ID             string `json:"id"`
	Ref            string `json:"ref"`
	Title          string `json:"title"`
	CustomTitle    string `json:"custom_title"`
	Cwd            string `json:"current_directory"`
	ListeningPorts []int  `json:"listening_ports"`
	Selected       bool   `json:"selected"`
}

// Workspaces lists workspaces in the cmux window. Returns an error when cmux is not running.
func (client Client) Workspaces() ([]Workspace, error) {
	out, err := client.run("--id-format", "both", "workspace", "list", "--json")
	if err != nil {
		return nil, err
	}
	return ParseWorkspaces(out)
}

func ParseWorkspaces(data []byte) ([]Workspace, error) {
	var payload struct {
		Workspaces []rawWorkspace `json:"workspaces"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	workspaces := make([]Workspace, 0, len(payload.Workspaces))
	for _, raw := range payload.Workspaces {
		title := raw.CustomTitle
		if title == "" {
			title = raw.Title
		}
		workspaces = append(workspaces, Workspace{
			ID: raw.ID, Ref: raw.Ref, Title: title, Cwd: raw.Cwd, Ports: raw.ListeningPorts, Selected: raw.Selected,
		})
	}
	return workspaces, nil
}

// AgentSession is one Claude session record from ~/.cmuxterm/claude-hook-sessions.json.
type AgentSession struct {
	SessionID   string `json:"sessionId"`
	WorkspaceID string `json:"workspaceId"`
	SurfaceID   string `json:"surfaceId"`
	Cwd         string `json:"cwd"`
	Lifecycle   string `json:"agentLifecycle"` // running | idle
	Runtime     string `json:"runtimeStatus"`
	TurnSettled bool   `json:"turnSettled"`
	PID         int    `json:"pid"`
	Alive       bool   `json:"alive"`
}

// HookSessionsPath is where cmux records Claude sessions it launched.
func HookSessionsPath() string {
	if path := os.Getenv("WK_CMUX_HOOK_SESSIONS"); path != "" {
		return path
	}
	return config.Expand("~/.cmuxterm/claude-hook-sessions.json")
}

// AgentSessions returns hook records keyed by Claude session id, with process liveness checked.
func AgentSessions() map[string]AgentSession {
	data, err := os.ReadFile(HookSessionsPath())
	if err != nil {
		return map[string]AgentSession{}
	}
	return ParseAgentSessions(data, pidAlive)
}

func ParseAgentSessions(data []byte, alive func(int) bool) map[string]AgentSession {
	var payload struct {
		Sessions map[string]AgentSession `json:"sessions"`
	}
	sessions := map[string]AgentSession{}
	if json.Unmarshal(data, &payload) != nil {
		return sessions
	}
	for _, session := range payload.Sessions {
		if session.SessionID == "" {
			continue
		}
		session.Alive = session.PID > 0 && alive(session.PID)
		existing, ok := sessions[session.SessionID]
		if !ok || (session.Alive && !existing.Alive) {
			sessions[session.SessionID] = session
		}
	}
	return sessions
}

func pidAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

func (client Client) Select(workspace string) error {
	_, err := client.run("select-workspace", "--workspace", workspace)
	return err
}

func (client Client) Close(workspace string) error {
	_, err := client.run("close-workspace", "--workspace", workspace)
	return err
}

// Activate brings the cmux app to the front.
func (client Client) Activate() {
	_ = exec.Command("open", "-b", "com.cmuxterm.app").Run()
}

// FocusSurface focuses the pane that holds surfaceID inside workspace.
func (client Client) FocusSurface(workspace, surfaceID string) error {
	out, err := client.run("--id-format", "both", "list-panels", "--workspace", workspace, "--json")
	if err != nil {
		return err
	}
	var payload struct {
		Surfaces []struct {
			ID      string `json:"id"`
			Ref     string `json:"ref"`
			PaneRef string `json:"pane_ref"`
			PaneID  string `json:"pane_id"`
		} `json:"surfaces"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return err
	}
	for _, surface := range payload.Surfaces {
		if !strings.EqualFold(surface.ID, surfaceID) {
			continue
		}
		pane := surface.PaneRef
		if pane == "" {
			pane = surface.PaneID
		}
		_, err := client.run("focus-pane", "--pane", pane, "--workspace", workspace)
		return err
	}
	return fmt.Errorf("surface %s not found in %s", surfaceID, workspace)
}

// CreateWorkspace opens a new focused workspace at cwd with the given layout JSON (may be empty).
func (client Client) CreateWorkspace(name, cwd, command, layout string) (string, error) {
	args := []string{"new-workspace", "--name", name, "--cwd", cwd, "--focus", "true"}
	if layout != "" {
		args = append(args, "--layout", layout)
	} else if command != "" {
		args = append(args, "--command", command)
	}
	out, err := client.run(args...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

type layoutSurface struct {
	Type    string `json:"type"`
	Name    string `json:"name,omitempty"`
	Command string `json:"command,omitempty"`
}

type layoutNode struct {
	Direction string       `json:"direction,omitempty"`
	Split     float64      `json:"split,omitempty"`
	Children  []layoutNode `json:"children,omitempty"`
	Pane      *layoutPane  `json:"pane,omitempty"`
}

type layoutPane struct {
	Surfaces []layoutSurface `json:"surfaces"`
}

func terminal(name, command string) layoutNode {
	return layoutNode{Pane: &layoutPane{Surfaces: []layoutSurface{{Type: "terminal", Name: name, Command: command}}}}
}

// Layout builds the 3-pane layout: claude on the left; server above git on the right.
// Panes inherit the workspace cwd.
func Layout(serverCmd, claudeCmd string) string {
	root := layoutNode{
		Direction: "horizontal",
		Split:     0.6,
		Children: []layoutNode{
			terminal("Claude", claudeCmd),
			{
				Direction: "vertical",
				Split:     0.5,
				Children:  []layoutNode{terminal("Server", serverCmd), terminal("Git", "")},
			},
		},
	}
	data, _ := json.Marshal(root)
	return string(data)
}

// NewSurface adds a terminal tab running command to the focused pane of workspace.
func (client Client) NewSurface(workspace, command string) error {
	_, err := client.run("new-surface", "--type", "terminal", "--workspace", workspace, "--command", command, "--focus", "true")
	return err
}
