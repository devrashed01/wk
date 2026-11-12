package core

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"wk/internal/config"

	"wk/internal/cmux"
	"wk/internal/gitops"
)

type OpenMode string

const (
	OpenResume OpenMode = "resume" // resume the latest session (or start one if none)
	OpenNew    OpenMode = "new"    // always start a fresh Claude session
	OpenNone   OpenMode = "none"   // open the workspace without Claude
)

type CheckoutVia string

const (
	ViaSwitch   CheckoutVia = "switch"   // check the branch out in the main worktree
	ViaWorktree CheckoutVia = "worktree" // create a sibling worktree for it
)

type OpenRequest struct {
	Task         string      `json:"task"`
	Session      string      `json:"session,omitempty"`
	Mode         OpenMode    `json:"mode,omitempty"`
	Via          CheckoutVia `json:"via,omitempty"`
	Stash        bool        `json:"stash,omitempty"`
	NewWorkspace bool        `json:"new_workspace,omitempty"`
	Single       bool        `json:"single,omitempty"` // a new workspace gets one Claude pane instead of the 3-pane layout
}

type OpenResult struct {
	Action    string `json:"action"` // focused | selected | added-tab | created | printed
	Workspace string `json:"workspace,omitempty"`
	Cwd       string `json:"cwd"`
	Command   string `json:"command,omitempty"` // shell fallback when cmux is unavailable
	Message   string `json:"message"`
}

// ErrNeedsCheckout means the branch has no worktree; the caller must pick ViaSwitch or ViaWorktree.
var ErrNeedsCheckout = errors.New("branch is not checked out: choose --via switch (main worktree) or --via worktree (new sibling folder)")

// FindTask resolves an id, ticket (ABC-123 or 123), or unique branch substring.
func FindTask(tasks []Task, query string) (Task, error) {
	query = strings.TrimSpace(query)
	for _, task := range tasks {
		if task.ID == query {
			return task, nil
		}
	}
	lower := strings.ToLower(query)
	var matches []Task
	for _, task := range tasks {
		ticket := strings.ToLower(task.Ticket)
		if ticket != "" && (ticket == lower || strings.HasSuffix(ticket, "-"+lower)) {
			matches = append(matches, task)
		}
	}
	if len(matches) == 0 {
		for _, task := range tasks {
			if strings.Contains(strings.ToLower(task.RepoName+" "+task.Branch), lower) {
				matches = append(matches, task)
			}
		}
	}
	switch len(matches) {
	case 0:
		return Task{}, fmt.Errorf("no task matches %q", query)
	case 1:
		return matches[0], nil
	}
	var names []string
	for _, task := range matches {
		names = append(names, "  "+task.ID)
	}
	return Task{}, fmt.Errorf("%q matches %d tasks, be more specific:\n%s", query, len(matches), strings.Join(names, "\n"))
}

// Open jumps to a task: focuses a live session, selects its workspace, or creates one.
func (service *Service) Open(request OpenRequest, progress Progress) (OpenResult, error) {
	snapshot, err := service.Snapshot()
	if err != nil {
		return OpenResult{}, err
	}
	task, err := FindTask(snapshot.Tasks, request.Task)
	if err != nil {
		return OpenResult{}, err
	}
	if request.Mode == "" {
		request.Mode = OpenResume
	}
	if task.Missing {
		return OpenResult{}, fmt.Errorf("worktree %s no longer exists; run cleanup (prune) or recreate it", task.Path)
	}
	if task.Detached && task.Path == "" {
		return OpenResult{}, errors.New("detached task has no worktree")
	}
	setupCmd := ""
	if task.Path == "" {
		if task.Path, setupCmd, err = service.checkout(task, request, progress); err != nil {
			return OpenResult{}, err
		}
		task.Workspace = nil
	}

	session, err := pickSession(task, request)
	if err != nil {
		return OpenResult{}, err
	}
	cwd := task.Path
	if session != nil {
		cwd = session.Cwd
	}
	if session != nil && session.Surface != "" && !request.NewWorkspace {
		if err := service.ensureCmux(); err == nil {
			if err := service.Cmux.Select(session.Workspace); err == nil {
				_ = service.Cmux.FocusSurface(session.Workspace, session.Surface)
				service.Cmux.Activate()
				return OpenResult{Action: "focused", Workspace: session.Workspace, Cwd: cwd, Message: "Focused running Claude session"}, nil
			}
		}
	}
	claudeCmd := claudeCommand(request.Mode, session)
	return service.openAt(openTarget{
		name: workspaceName(task), cwd: cwd, repo: task.Repo, existing: task.Workspace,
		claudeCmd: claudeCmd, setupCmd: setupCmd, newWorkspace: request.NewWorkspace, single: request.Single,
	})
}

type openTarget struct {
	name, cwd, repo     string
	existing            *Workspace
	claudeCmd, setupCmd string
	newWorkspace        bool
	single              bool // one pane instead of the 3-pane layout
}

// openAt selects an existing workspace (adding a Claude tab if asked) or creates a 3-pane one.
func (service *Service) openAt(target openTarget) (OpenResult, error) {
	cwd := target.cwd
	if err := service.ensureCmux(); err != nil {
		if errors.Is(err, cmux.ErrAccessDenied) {
			return OpenResult{}, err
		}
		command := joinCommands("cd "+shellQuote(cwd), target.setupCmd, target.claudeCmd)
		return OpenResult{Action: "printed", Cwd: cwd, Command: command, Message: "cmux is not running; run this in a terminal"}, nil
	}
	claudeCmd := target.claudeCmd
	if !service.Config.AutoStartClaude {
		claudeCmd = stageClaude(claudeCmd)
	}
	if target.existing != nil && !target.newWorkspace {
		existing := target.existing
		if err := service.Cmux.Select(existing.ID); err != nil {
			return OpenResult{}, err
		}
		action, message := "selected", "Switched to workspace "+existing.Title
		if claudeCmd != "" {
			if err := service.Cmux.NewSurface(existing.ID, joinCommands("cd "+shellQuote(cwd), claudeCmd)); err != nil {
				return OpenResult{}, err
			}
			action, message = "added-tab", "Switched to "+existing.Title+" and opened Claude in a new tab"
		}
		service.Cmux.Activate()
		return OpenResult{Action: action, Workspace: existing.ID, Cwd: cwd, Message: message}, nil
	}
	settings := service.repoSettings(target.repo)
	panes := service.layoutFor(settings)
	if settings.NoLayout || target.single {
		panes = config.Layout{Panes: []config.Pane{{Kind: "claude"}}}
	}
	specs := paneSpecs(panes, claudeCmd, target.setupCmd, settings.ServerCmd)
	layout := ""
	if len(specs) > 1 {
		layout = cmux.BuildLayout(panes.Arrange, panes.MainSize, specs)
	}
	ref, err := service.Cmux.CreateWorkspace(target.name, cwd, specs[0].Command, layout)
	if err != nil {
		return OpenResult{}, err
	}
	service.Cmux.Activate()
	return OpenResult{Action: "created", Workspace: ref, Cwd: cwd, Message: "Opened new workspace " + target.name}, nil
}

func (service *Service) ensureCmux() error {
	_, err := service.Cmux.Workspaces()
	if err == nil || errors.Is(err, cmux.ErrAccessDenied) {
		return err // denied: cmux is up, so waiting for it would not help
	}
	service.Cmux.Activate()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(400 * time.Millisecond)
		if _, err := service.Cmux.Workspaces(); err == nil {
			return nil
		}
	}
	return errors.New("cmux is not running")
}

// checkout makes a worktree available for a branch-only task and returns its path.
func (service *Service) checkout(task Task, request OpenRequest, progress Progress) (path, setupCmd string, err error) {
	switch request.Via {
	case ViaSwitch:
		progress.Step("Switching %s to %s", task.RepoLabel, task.Branch)
		if err := service.Ops.Switch(task.Repo, task.Branch, request.Stash); err != nil {
			return "", "", err
		}
		return task.Repo, "", nil
	case ViaWorktree:
		path := gitops.WorktreePath(task.Repo, task.Branch)
		progress.Step("Creating worktree %s", path)
		if err := service.Ops.AddWorktree(task.Repo, path, task.Branch, "", false); err != nil {
			return "", "", err
		}
		return path, service.PrepareWorktree(task.Repo, path, progress), nil
	}
	return "", "", ErrNeedsCheckout
}

// pickSession chooses the session to resume: an explicit id, else the newest one in the worktree.
func pickSession(task Task, request OpenRequest) (*Session, error) {
	if request.Session != "" {
		for index := range task.Sessions {
			if strings.HasPrefix(task.Sessions[index].ID, request.Session) {
				return &task.Sessions[index], nil
			}
		}
		return nil, fmt.Errorf("session %s does not belong to %s", request.Session, task.ID)
	}
	if request.Mode != OpenResume {
		return nil, nil
	}
	for index := range task.Sessions {
		session := &task.Sessions[index]
		if session.State == StateRunning || session.State == StateWaiting {
			return session, nil
		}
	}
	for index := range task.Sessions {
		session := &task.Sessions[index]
		if session.Cwd == task.Path && session.Branch == task.Branch {
			return session, nil
		}
	}
	return nil, nil
}

func claudeCommand(mode OpenMode, session *Session) string {
	switch {
	case mode == OpenNone:
		return ""
	case session != nil && mode != OpenNew:
		return "claude --resume " + session.ID
	}
	return "claude"
}

// stageClaude turns "claude" or "claude --resume <id>" into a command that only types it at the
// prompt, so Claude (and a resume, which re-reads the whole transcript and costs tokens) waits for Enter.
// cmux types pane commands into the shell, and zsh's `print -z` puts text in the next line's edit
// buffer. Other shells have no equivalent, so there the command still runs right away.
func stageClaude(command string) string {
	if command != "claude" && !strings.HasPrefix(command, "claude ") {
		return command
	}
	if shell := os.Getenv("SHELL"); shell != "" && filepath.Base(shell) != "zsh" {
		return command
	}
	return "print -z " + shellQuote(command)
}

func workspaceName(task Task) string {
	if task.Ticket != "" {
		return task.RepoLabel + " " + task.Ticket
	}
	return task.RepoLabel + " " + task.Branch
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
