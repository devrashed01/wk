package core

import (
	"fmt"
	"hash/fnv"
	"strings"

	"wk/internal/cmux"
)

// wk mirrors a little of each task into its cmux workspace so the two feel like one tool:
// the task note under the title, a per-repo tab color and a git status pill.

// StatusKey is the cmux status entry wk owns.
const StatusKey = "wk.git"

// RepoColors are the tab tints, picked per repo label so a repo keeps its color.
var RepoColors = []string{"#0090FF", "#46A758", "#F76B15", "#8E4EC6", "#12A594", "#E5484D", "#D6409F", "#FFB224"}

func RepoColor(label string) string {
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(label))
	return RepoColors[hash.Sum32()%uint32(len(RepoColors))]
}

func isRepoColor(color string) bool {
	for _, candidate := range RepoColors {
		if strings.EqualFold(candidate, color) {
			return true
		}
	}
	return false
}

// GitStatus is the pill for a task: uncommitted files, unpushed/unpulled commits, merged.
func GitStatus(task Task) cmux.Status {
	var parts []string
	if task.Dirty > 0 {
		parts = append(parts, fmt.Sprintf("%d changed", task.Dirty))
	}
	if task.Ahead > 0 {
		parts = append(parts, fmt.Sprintf("↑%d", task.Ahead))
	}
	if task.Behind > 0 {
		parts = append(parts, fmt.Sprintf("↓%d", task.Behind))
	}
	switch {
	case len(parts) > 0 && task.Dirty > 0:
		return cmux.Status{Value: strings.Join(parts, " · "), Icon: "pencil", Color: "#F59E0B", Priority: 40}
	case len(parts) > 0:
		return cmux.Status{Value: strings.Join(parts, " "), Icon: "arrow.up.arrow.down", Color: "#4C8DFF", Priority: 40}
	case (task.Merged || (task.PR != nil && task.PR.State == "merged")) && !task.IsBase:
		return cmux.Status{Value: "merged", Icon: "checkmark.circle", Color: "#46A758", Priority: 40}
	case task.Gone:
		return cmux.Status{Value: "remote branch gone", Icon: "exclamationmark.triangle", Color: "#8B8D98", Priority: 40}
	}
	return cmux.Status{}
}

type decoration struct {
	description, color string
	status             cmux.Status
}

// DecorateCmux brings every open workspace up to date with its task. Only changes are sent,
// and descriptions or colors the user set in cmux themselves are left alone.
// A call made while another is still running is skipped; the next snapshot catches up.
func (service *Service) DecorateCmux(tasks []Task) {
	if !service.decorateMutex.TryLock() {
		return
	}
	defer service.decorateMutex.Unlock()
	if service.decorated == nil {
		service.decorated = map[string]decoration{}
	}
	workspaces, err := service.Cmux.Workspaces()
	if err != nil {
		return
	}
	byID := map[string]cmux.Workspace{}
	for _, workspace := range workspaces {
		byID[strings.ToUpper(workspace.ID)] = workspace
	}
	if service.Config.PlainCmux {
		for id, previous := range service.decorated {
			if workspace, ok := byID[id]; ok {
				service.undecorate(workspace, previous)
			}
		}
		service.decorated = map[string]decoration{}
		return
	}
	seen := map[string]bool{}
	for _, task := range tasks {
		if task.Workspace == nil || task.ParentID != "" {
			continue
		}
		id := strings.ToUpper(task.Workspace.ID)
		workspace, ok := byID[id]
		if !ok || seen[id] {
			continue
		}
		seen[id] = true
		service.decorate(workspace, task)
	}
	for id := range service.decorated {
		if !seen[id] {
			delete(service.decorated, id) // closed, or no longer a task's workspace
		}
	}
}

func (service *Service) decorate(workspace cmux.Workspace, task Task) {
	id := strings.ToUpper(workspace.ID)
	previous, known := service.decorated[id]
	want := decoration{description: strings.TrimSpace(task.Note), color: RepoColor(task.RepoLabel), status: GitStatus(task)}
	applied := previous

	// Description: write the note; clear it only when wk put the current text there.
	if workspace.Description != want.description {
		ours := workspace.Description == "" || (known && workspace.Description == previous.description)
		if want.description != "" || ours {
			if service.Cmux.SetDescription(workspace.ID, want.description) == nil {
				applied.description = want.description
			}
		}
	} else {
		applied.description = want.description
	}

	// Color: don't repaint a tab the user colored by hand.
	if !strings.EqualFold(workspace.Color, want.color) {
		if workspace.Color == "" || isRepoColor(workspace.Color) {
			if service.Cmux.SetColor(workspace.ID, want.color) == nil {
				applied.color = want.color
			}
		}
	} else {
		applied.color = want.color
	}

	// Status pills aren't in the workspace list, so send on first sight and on change.
	if !known || previous.status != want.status {
		if service.Cmux.SetStatus(workspace.ID, StatusKey, want.status) == nil {
			applied.status = want.status
		}
	}
	service.decorated[id] = applied
}

func (service *Service) undecorate(workspace cmux.Workspace, previous decoration) {
	if previous.description != "" && workspace.Description == previous.description {
		_ = service.Cmux.SetDescription(workspace.ID, "")
	}
	if previous.color != "" && strings.EqualFold(workspace.Color, previous.color) {
		_ = service.Cmux.SetColor(workspace.ID, "")
	}
	_ = service.Cmux.SetStatus(workspace.ID, StatusKey, cmux.Status{})
}
