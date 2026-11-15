package core

import (
	"fmt"
	"hash/fnv"
	"strings"

	"wk/internal/cmux"
	"wk/internal/prs"
)

// wk mirrors a little of each task into its cmux workspace so the two feel like one tool:
// the task note under the title, a per-repo tab color and a git status pill.

// StatusKey and PRStatusKey are the cmux status entries wk owns.
const (
	StatusKey     = "wk.git"
	PRStatusKey   = "wk.pr"
	JiraStatusKey = "wk.jira"
)

// Description is what wk shows under the workspace title: the Jira ticket's title, then the wk note.
func Description(task Task) string {
	var lines []string
	if task.Issue != nil && strings.TrimSpace(task.Issue.Summary) != "" {
		lines = append(lines, strings.TrimSpace(task.Issue.Summary))
	}
	if note := strings.TrimSpace(task.Note); note != "" {
		lines = append(lines, note)
	}
	return strings.Join(lines, "\n")
}

// JiraStatus is the ticket pill: "ABC-4533 · In Progress", grey to-do, blue in progress, green done.
func JiraStatus(task Task) cmux.Status {
	if task.Issue == nil || task.Issue.Status == "" {
		return cmux.Status{}
	}
	color := "#8B8D98"
	switch task.Issue.Category {
	case "indeterminate":
		color = "#0090FF"
	case "done":
		color = "#46A758"
	}
	return cmux.Status{Value: task.Issue.Key + " · " + task.Issue.Status, Icon: "ticket", Color: color, Priority: 50}
}

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

// PRStatus is the pill for a task's pull requests: "#775 draft · dev open · stg draft". cmux shows
// GitHub PRs on its own, so a lone GitHub PR is left to it.
func PRStatus(task Task) cmux.Status {
	type entry struct {
		label string
		pr    prs.PR
	}
	var entries []entry
	if task.PR != nil {
		entries = append(entries, entry{fmt.Sprintf("#%d", task.PR.Number), *task.PR})
	}
	for _, env := range task.EnvPRs {
		entries = append(entries, entry{env.Env, env.PR})
	}
	if len(entries) == 0 || (len(entries) == 1 && task.PR != nil && strings.Contains(task.PR.URL, "github.com")) {
		return cmux.Status{}
	}
	parts := make([]string, 0, len(entries))
	color, live, failing, changes := "#8E4EC6", false, false, false // purple: everything merged
	for _, item := range entries {
		state := item.pr.State
		if item.pr.Live() && item.pr.Checks == "failing" {
			state, failing = "failing", true
		}
		if item.pr.Live() && item.pr.Review == "changes_requested" {
			changes = true
		}
		live = live || item.pr.Live()
		parts = append(parts, item.label+" "+state)
	}
	switch {
	case failing:
		color = "#E5484D"
	case changes:
		color = "#F76B15"
	case live:
		color = "#46A758"
	}
	return cmux.Status{Value: strings.Join(parts, " · "), Icon: "arrow.triangle.pull", Color: color, Priority: 30}
}

type decoration struct {
	description, color string
	status, prStatus   cmux.Status
	jiraStatus         cmux.Status
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
	want := decoration{description: Description(task), jiraStatus: JiraStatus(task), color: RepoColor(task.RepoLabel), status: GitStatus(task), prStatus: PRStatus(task)}
	applied := previous

	// Description: write the note; clear it only when wk put the current text there.
	if workspace.Description != want.description {
		// wk's own text from before (the note alone, or an older ticket title) counts as ours too.
		ours := workspace.Description == "" || (known && workspace.Description == previous.description) ||
			workspace.Description == strings.TrimSpace(task.Note) ||
			(task.Issue != nil && strings.HasPrefix(workspace.Description, task.Issue.Summary))
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
	if !known || previous.jiraStatus != want.jiraStatus {
		if service.Cmux.SetStatus(workspace.ID, JiraStatusKey, want.jiraStatus) == nil {
			applied.jiraStatus = want.jiraStatus
		}
	}
	if !known || previous.prStatus != want.prStatus {
		if service.Cmux.SetStatus(workspace.ID, PRStatusKey, want.prStatus) == nil {
			applied.prStatus = want.prStatus
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
	_ = service.Cmux.SetStatus(workspace.ID, PRStatusKey, cmux.Status{})
	_ = service.Cmux.SetStatus(workspace.ID, JiraStatusKey, cmux.Status{})
}
