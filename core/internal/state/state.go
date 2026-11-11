// Package state stores wk's own metadata: pins, notes, hidden tasks, session aliases.
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"time"

	"wk/internal/config"
)

type TrashedSession struct {
	ID        string    `json:"id"`
	From      string    `json:"from"` // original transcript path
	TrashedAt time.Time `json:"trashed_at"`
}

type State struct {
	Pinned  []string                  `json:"pinned"`
	Hidden  []string                  `json:"hidden"`
	Notes   map[string]string         `json:"notes"`
	Aliases map[string]string         `json:"aliases"` // session id -> display name
	Trash   map[string]TrashedSession `json:"trash"`
}

func path() string { return filepath.Join(config.StateDir(), "state.json") }

// TrashDir holds transcripts moved out of ~/.claude/projects.
func TrashDir() string { return filepath.Join(config.StateDir(), "trash") }

func Load() (*State, error) {
	st := &State{}
	data, err := os.ReadFile(path())
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if len(data) > 0 {
		if err := json.Unmarshal(data, st); err != nil {
			return nil, err
		}
	}
	if st.Notes == nil {
		st.Notes = map[string]string{}
	}
	if st.Aliases == nil {
		st.Aliases = map[string]string{}
	}
	if st.Trash == nil {
		st.Trash = map[string]TrashedSession{}
	}
	return st, nil
}

func (st *State) Save() error {
	if err := os.MkdirAll(config.StateDir(), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp := path() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path())
}

func (st *State) IsPinned(taskID string) bool { return slices.Contains(st.Pinned, taskID) }
func (st *State) IsHidden(taskID string) bool { return slices.Contains(st.Hidden, taskID) }

func (st *State) SetPinned(taskID string, pinned bool) {
	st.Pinned = toggle(st.Pinned, taskID, pinned)
}

func (st *State) SetHidden(taskID string, hidden bool) {
	st.Hidden = toggle(st.Hidden, taskID, hidden)
}

func (st *State) SetNote(taskID, note string) {
	if note == "" {
		delete(st.Notes, taskID)
		return
	}
	st.Notes[taskID] = note
}

func (st *State) SetAlias(sessionID, alias string) {
	if alias == "" {
		delete(st.Aliases, sessionID)
		return
	}
	st.Aliases[sessionID] = alias
}

// RenameTask moves pins/notes/hidden flags from one task id to another (branch rename).
func (st *State) RenameTask(oldID, newID string) {
	for index, taskID := range st.Pinned {
		if taskID == oldID {
			st.Pinned[index] = newID
		}
	}
	for index, taskID := range st.Hidden {
		if taskID == oldID {
			st.Hidden[index] = newID
		}
	}
	if note, ok := st.Notes[oldID]; ok {
		delete(st.Notes, oldID)
		st.Notes[newID] = note
	}
}

func toggle(list []string, item string, on bool) []string {
	present := slices.Contains(list, item)
	switch {
	case on && !present:
		return append(list, item)
	case !on && present:
		return slices.DeleteFunc(list, func(existing string) bool { return existing == item })
	}
	return list
}
