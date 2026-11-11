package core

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"wk/internal/claudeidx"
	"wk/internal/gitops"
	"wk/internal/state"
)

// Sessions lists every session under the roots (newest first), optionally filtered by a query
// matched against title, alias, first prompt, branch, repo and id.
func (service *Service) Sessions(query string, includeTrash bool) ([]Session, error) {
	snapshot, err := service.Snapshot()
	if err != nil {
		return nil, err
	}
	terms := strings.Fields(strings.ToLower(query))
	var sessions []Session
	for _, session := range service.allSessions {
		if matches(session, terms) {
			sessions = append(sessions, session)
		}
	}
	if includeTrash {
		for id, trashed := range service.State.Trash {
			raw, err := claudeidx.ParseFile(filepath.Join(state.TrashDir(), id+".jsonl"))
			if err != nil {
				continue
			}
			session := service.toSession(raw, nil, nil)
			session.ID = id
			session.Trashed = true
			session.State = StateOrphan
			session.Repo = repoForCwd(snapshot.Repos, trashed.From, raw.Cwd)
			if matches(session, terms) {
				sessions = append(sessions, session)
			}
		}
	}
	return sessions, nil
}

func matches(session Session, terms []string) bool {
	haystack := strings.ToLower(strings.Join([]string{
		session.ID, session.Title, session.Alias, session.FirstPrompt, session.Cwd, strings.Join(session.Branches, " "),
	}, " "))
	for _, term := range terms {
		if !strings.Contains(haystack, term) {
			return false
		}
	}
	return true
}

func (service *Service) findSession(idPrefix string) (Session, error) {
	sessions, err := service.Sessions("", false)
	if err != nil {
		return Session{}, err
	}
	var found []Session
	for _, session := range sessions {
		if strings.HasPrefix(session.ID, idPrefix) {
			found = append(found, session)
		}
	}
	switch len(found) {
	case 0:
		return Session{}, fmt.Errorf("no session %q", idPrefix)
	case 1:
		return found[0], nil
	}
	return Session{}, fmt.Errorf("session prefix %q is ambiguous", idPrefix)
}

type ResumeRequest struct {
	Session      string `json:"session"`
	NewWorkspace bool   `json:"new_workspace,omitempty"`
	Recreate     bool   `json:"recreate,omitempty"` // orphan: recreate the worktree at the original path
}

// Resume opens a session wherever it lives, recreating a deleted worktree if asked.
func (service *Service) Resume(request ResumeRequest, progress Progress) (OpenResult, error) {
	session, err := service.findSession(request.Session)
	if err != nil {
		return OpenResult{}, err
	}
	if session.Surface != "" && !request.NewWorkspace && service.ensureCmux() == nil {
		if err := service.Cmux.Select(session.Workspace); err == nil {
			_ = service.Cmux.FocusSurface(session.Workspace, session.Surface)
			service.Cmux.Activate()
			return OpenResult{Action: "focused", Workspace: session.Workspace, Cwd: session.Cwd, Message: "Focused running Claude session"}, nil
		}
	}
	setupCmd := ""
	if !session.CwdExists {
		if !request.Recreate {
			return OpenResult{}, fmt.Errorf("folder %s no longer exists; resume with recreate to restore the worktree there", session.Cwd)
		}
		if setupCmd, err = service.recreateWorktree(session, progress); err != nil {
			return OpenResult{}, err
		}
	}
	label := RepoLabel(session.Repo)
	if session.Repo == "" {
		label = strings.ToUpper(filepath.Base(session.Cwd))
	}
	name := label + " " + firstNonEmpty(gitops.Ticket(session.Branch), session.Branch, truncateTitle(session.DisplayTitle()))
	return service.openAt(openTarget{
		name: name, cwd: session.Cwd, repo: session.Repo, existing: service.workspaceAt(session.Cwd),
		claudeCmd: "claude --resume " + session.ID, setupCmd: setupCmd, newWorkspace: request.NewWorkspace,
	})
}

func (service *Service) recreateWorktree(session Session, progress Progress) (string, error) {
	if session.Repo == "" || session.Branch == "" {
		return "", errors.New("cannot tell which repo/branch this session belonged to")
	}
	if !service.Ops.BranchExists(session.Repo, session.Branch) {
		if _, err := service.Git.Run(session.Repo, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/"+session.Branch); err != nil {
			return "", fmt.Errorf("branch %s no longer exists locally or on origin", session.Branch)
		}
		progress.Step("Recreating %s from origin into %s", session.Branch, session.Cwd)
		if err := service.Ops.AddWorktree(session.Repo, session.Cwd, "origin/"+session.Branch, "", false); err != nil {
			return "", err
		}
	} else {
		progress.Step("Recreating worktree %s on %s", session.Cwd, session.Branch)
		if err := service.Ops.AddWorktree(session.Repo, session.Cwd, session.Branch, "", false); err != nil {
			return "", err
		}
	}
	return service.PrepareWorktree(session.Repo, session.Cwd, progress), nil
}

// RenameSession sets a wk-only display name; Claude's own files are not modified.
func (service *Service) RenameSession(idPrefix, alias string) error {
	session, err := service.findSession(idPrefix)
	if err != nil {
		return err
	}
	service.State.SetAlias(session.ID, alias)
	return service.SaveState()
}

// TrashSession moves a transcript (and its sidecar folder) into wk's trash.
func (service *Service) TrashSession(idPrefix string) error {
	session, err := service.findSession(idPrefix)
	if err != nil {
		return err
	}
	if session.State == StateRunning || session.State == StateWaiting {
		return errors.New("session is still running in cmux; close it first")
	}
	return service.trash(session.ID)
}

func (service *Service) trash(id string) error {
	var source string
	for path, raw := range service.Index.Sessions {
		if raw.ID == id {
			source = path
		}
	}
	if source == "" {
		return fmt.Errorf("transcript for %s not found", id)
	}
	if err := os.MkdirAll(state.TrashDir(), 0o755); err != nil {
		return err
	}
	if err := os.Rename(source, filepath.Join(state.TrashDir(), id+".jsonl")); err != nil {
		return err
	}
	sidecar := strings.TrimSuffix(source, ".jsonl")
	if exists(sidecar) {
		_ = os.Rename(sidecar, filepath.Join(state.TrashDir(), id))
	}
	service.State.Trash[id] = state.TrashedSession{ID: id, From: source, TrashedAt: time.Now()}
	delete(service.Index.Sessions, source)
	service.indexDirty = true
	return service.SaveState()
}

// RestoreSession moves a trashed transcript back where it came from.
func (service *Service) RestoreSession(idPrefix string) error {
	for id, trashed := range service.State.Trash {
		if !strings.HasPrefix(id, idPrefix) {
			continue
		}
		if exists(trashed.From) {
			return fmt.Errorf("%s already exists", trashed.From)
		}
		if err := os.MkdirAll(filepath.Dir(trashed.From), 0o755); err != nil {
			return err
		}
		if err := os.Rename(filepath.Join(state.TrashDir(), id+".jsonl"), trashed.From); err != nil {
			return err
		}
		sidecar := filepath.Join(state.TrashDir(), id)
		if exists(sidecar) {
			_ = os.Rename(sidecar, strings.TrimSuffix(trashed.From, ".jsonl"))
		}
		delete(service.State.Trash, id)
		return service.SaveState()
	}
	return fmt.Errorf("no trashed session %q", idPrefix)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func truncateTitle(title string) string {
	runes := []rune(title)
	if len(runes) > 30 {
		return string(runes[:29]) + "…"
	}
	return title
}

// repoForCwd finds the repo for a trashed session's cwd (best effort).
func repoForCwd(repos []Repo, _ string, cwd string) string {
	for _, repo := range repos {
		if cwd == repo.Path || strings.HasPrefix(cwd, repo.Path+"/") || strings.HasPrefix(filepath.Base(cwd), filepath.Base(repo.Path)+"-") {
			return repo.Path
		}
	}
	return ""
}
