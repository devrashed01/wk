package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	"wk/internal/config"
	"wk/internal/core"
)

// Protocol (one JSON object per line):
//   request   {"id":"1","cmd":"snapshot","args":{...}}
//   response  {"id":"1","ok":true,"data":...} | {"id":"1","ok":false,"error":"..."}
//   progress  {"id":"1","event":"progress","level":"step|warn","message":"..."}
//   fetching  {"event":"fetching","data":{"prs":true,"jira":false}}  (no id; PR/Jira fetches start or stop)
// Requests are handled one at a time so git and state writes never race.

type request struct {
	ID   string          `json:"id"`
	Cmd  string          `json:"cmd"`
	Args json.RawMessage `json:"args"`
}

type response struct {
	ID      string `json:"id"`
	OK      bool   `json:"ok"`
	Data    any    `json:"data,omitempty"`
	Error   string `json:"error,omitempty"`
	Event   string `json:"event,omitempty"`
	Level   string `json:"level,omitempty"`
	Message string `json:"message,omitempty"`
}

type writer struct {
	mutex   sync.Mutex
	encoder *json.Encoder
}

func (out *writer) send(value response) {
	out.mutex.Lock()
	defer out.mutex.Unlock()
	_ = out.encoder.Encode(value)
}

type serveProgress struct {
	id  string
	out *writer
}

func (progress serveProgress) Step(format string, args ...any) {
	progress.out.send(response{ID: progress.id, Event: "progress", Level: "step", Message: fmt.Sprintf(format, args...)})
}

func (progress serveProgress) Warn(format string, args ...any) {
	progress.out.send(response{ID: progress.id, Event: "progress", Level: "warn", Message: fmt.Sprintf(format, args...)})
}

func serve() error {
	service, err := core.New()
	if err != nil {
		return err
	}
	out := &writer{encoder: json.NewEncoder(os.Stdout)}

	// Tell the app when PR or Jira fetches start and stop, so it can show they're running.
	// State is read and sent under one lock, so the last event always matches the truth.
	var fetchMutex sync.Mutex
	notify := func() {
		fetchMutex.Lock()
		defer fetchMutex.Unlock()
		out.send(response{Event: "fetching", Data: service.Fetching()})
	}
	if service.PRs != nil {
		service.PRs.OnBusy = notify
	}
	if service.Jira != nil {
		service.Jira.OnBusy = notify
	}

	lines := make(chan []byte)
	var scanErr error
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 1024*1024), 16*1024*1024)
		for scanner.Scan() {
			lines <- append([]byte(nil), scanner.Bytes()...)
		}
		scanErr = scanner.Err()
		close(lines)
	}()

	// Keep PRs and Jira fresh while nothing else asks for a snapshot (the caches skip anything
	// newer than their TTL). Runs on this loop, so it never races a request.
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			_ = service.RefreshRemote(false)
		case line, ok := <-lines:
			if !ok {
				return scanErr
			}
			var req request
			if err := json.Unmarshal(line, &req); err != nil {
				out.send(response{Error: "bad request: " + err.Error()})
				continue
			}
			data, err := dispatch(service, req, serveProgress{id: req.ID, out: out})
			if err != nil {
				out.send(response{ID: req.ID, Error: err.Error()})
				continue
			}
			out.send(response{ID: req.ID, OK: true, Data: data})
		}
	}
}

type taskArgs struct {
	Task    string   `json:"task"`
	Session string   `json:"session"`
	Value   bool     `json:"value"`
	Text    string   `json:"text"`
	Branch  string   `json:"branch"`
	Stash   bool     `json:"stash"`
	Repo    string   `json:"repo"`
	New     string   `json:"new"`
	Base    string   `json:"base"`
	Query   string   `json:"query"`
	Trash   bool     `json:"trash"`
	Force   bool     `json:"force"`
	IDs     []string `json:"ids"`
}

func decode[T any](raw json.RawMessage) (T, error) {
	var value T
	if len(raw) == 0 {
		return value, nil
	}
	err := json.Unmarshal(raw, &value)
	return value, err
}

func dispatch(service *core.Service, req request, progress core.Progress) (any, error) {
	// Config and state can be edited from the CLI while the app runs: reload cheap files each time.
	if cfg, err := config.Load(); err == nil {
		service.Config = cfg
	}
	switch req.Cmd {
	case "snapshot":
		scope := core.FullScope
		if len(req.Args) > 0 {
			var err error
			if scope, err = decode[core.Scope](req.Args); err != nil {
				return nil, err
			}
		}
		snapshot, err := service.SnapshotScoped(scope)
		if err == nil && snapshot.CmuxRunning {
			go service.DecorateCmux(snapshot.Tasks)
		}
		return snapshot, err
	case "open":
		args, err := decode[core.OpenRequest](req.Args)
		if err != nil {
			return nil, err
		}
		return service.Open(args, progress)
	case "resume":
		args, err := decode[core.ResumeRequest](req.Args)
		if err != nil {
			return nil, err
		}
		return service.Resume(args, progress)
	case "new":
		args, err := decode[core.NewTaskRequest](req.Args)
		if err != nil {
			return nil, err
		}
		return service.NewTask(args, progress)
	case "remove_plan":
		args, err := decode[taskArgs](req.Args)
		if err != nil {
			return nil, err
		}
		return service.PlanRemove(args.Task)
	case "remove":
		args, err := decode[core.RemoveRequest](req.Args)
		if err != nil {
			return nil, err
		}
		return service.ApplyRemove(args, progress)
	case "cleanup":
		return service.Cleanup()
	case "config_get":
		return service.Config, nil
	case "config_put":
		cfg, err := decode[config.Config](req.Args)
		if err != nil {
			return nil, err
		}
		if err := config.Save(cfg); err != nil {
			return nil, err
		}
		service.Config = cfg
		return cfg, nil
	}

	args, err := decode[taskArgs](req.Args)
	if err != nil {
		return nil, err
	}
	message := func(text string, err error) (any, error) {
		if err != nil {
			return nil, err
		}
		return map[string]string{"message": text}, nil
	}
	switch req.Cmd {
	case "show":
		return service.Show(args.Task)
	case "sessions":
		return service.Sessions(args.Query, args.Trash)
	case "repo_refs":
		return service.RepoRefs(args.Repo)
	case "cleanup_apply":
		return service.ApplyCleanup(args.IDs, args.Force, progress)
	case "switch":
		return message(service.SwitchBranch(args.Task, args.Branch, args.Stash))
	case "rename_branch":
		return message(service.RenameBranch(args.Task, args.New))
	case "pull":
		return message(service.Pull(args.Task))
	case "push":
		return message(service.PushBranch(args.Repo, args.Branch))
	case "worktree_add":
		return service.AddWorktree(args.Repo, args.Branch, args.New, args.Base, progress)
	case "jira_detect":
		site, err := service.DetectJiraSite()
		return message(site, err)
	case "refresh_jira":
		return message("ok", service.RefreshJira())
	case "refresh_prs":
		return message("ok", service.RefreshPRs())
	case "refresh_remote":
		return message("ok", service.RefreshRemote(true))
	case "fetching":
		return service.Fetching(), nil
	case "close_workspace":
		return message(service.CloseWorkspace(args.Task))
	case "pin":
		return message("ok", service.SetPinned(args.Task, args.Value))
	case "hide":
		return message("ok", service.SetHidden(args.Task, args.Value))
	case "note":
		return message("ok", service.SetNote(args.Task, args.Text))
	case "session_rename":
		return message("ok", service.RenameSession(args.Session, args.Text))
	case "trash":
		return message("Moved to trash", service.TrashSession(args.Session))
	case "restore":
		return message("Restored", service.RestoreSession(args.Session))
	}
	return nil, fmt.Errorf("unknown command %q", req.Cmd)
}
