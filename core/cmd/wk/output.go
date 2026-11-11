package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"wk/internal/config"
	"wk/internal/core"
)

var useColor = os.Getenv("NO_COLOR") == "" && isTerminal(os.Stdout)

func isTerminal(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func paint(code, text string) string {
	if !useColor {
		return text
	}
	return "\x1b[" + code + "m" + text + "\x1b[0m"
}

func bold(text string) string   { return paint("1", text) }
func dim(text string) string    { return paint("2", text) }
func red(text string) string    { return paint("31", text) }
func green(text string) string  { return paint("32", text) }
func yellow(text string) string { return paint("33", text) }
func cyan(text string) string   { return paint("36", text) }

// taskBadges renders the status column: ▶ running, ● waiting, ◉ open, ✎ dirty, ↑ unpushed.
func taskBadges(task core.Task) string {
	var badges []string
	switch {
	case task.Running > 0:
		badges = append(badges, cyan("▶"))
	case task.Waiting > 0:
		badges = append(badges, yellow("●"))
	case task.Workspace != nil:
		badges = append(badges, green("◉"))
	default:
		badges = append(badges, " ")
	}
	if task.Pinned {
		badges = append(badges, "★")
	} else {
		badges = append(badges, " ")
	}
	return strings.Join(badges, "")
}

func taskLine(task core.Task) string {
	title := ""
	if len(task.Sessions) > 0 {
		title = task.Sessions[0].DisplayTitle()
	}
	extras := []string{}
	if task.Dirty > 0 {
		extras = append(extras, yellow(fmt.Sprintf("✎%d", task.Dirty)))
	}
	if task.Ahead > 0 {
		extras = append(extras, fmt.Sprintf("↑%d", task.Ahead))
	}
	if task.Path == "" {
		extras = append(extras, dim("no folder"))
	} else if !task.MainWorktree {
		extras = append(extras, dim("worktree"))
	}
	if len(task.EnvBranches) > 0 {
		var envs []string
		for _, branch := range task.EnvBranches {
			if _, suffix, ok := strings.Cut(branch[strings.LastIndex(branch, "-"):], "-"); ok {
				envs = append(envs, suffix)
			}
		}
		extras = append(extras, dim("+"+strings.Join(envs, "·")))
	}
	if task.Note != "" {
		extras = append(extras, dim("“"+task.Note+"”"))
	}
	return fmt.Sprintf("%s %-10s %-44s %-8s %s %s",
		taskBadges(task), truncate(task.RepoLabel, 10), truncate(task.Branch, 44), ago(task.LastActivity),
		truncate(title, 50), strings.Join(extras, " "))
}

func sessionLine(session core.Session) string {
	state := map[core.SessionState]string{
		core.StateRunning: cyan("▶ running"),
		core.StateWaiting: yellow("● waiting"),
		core.StateIdle:    dim("  idle   "),
		core.StateOrphan:  red("✗ orphan "),
	}[session.State]
	if session.Trashed {
		state = red("🗑 trash  ")
	}
	repo := core.RepoLabel(session.Repo)
	if session.Repo == "" {
		repo = "?"
	}
	return fmt.Sprintf("%s %s %-8s %-10s %-34s %s", session.ID[:8], state, ago(session.Last), truncate(repo, 10),
		truncate(session.Branch, 34), truncate(session.DisplayTitle(), 60))
}

func printDetail(detail core.TaskDetail) {
	task := detail.Task
	fmt.Printf("%s %s\n", bold(task.RepoLabel+" "+task.Branch), dim(task.ID))
	if task.Path != "" {
		fmt.Println("  folder     " + config.Collapse(task.Path))
	} else {
		fmt.Println("  folder     " + dim("not checked out"))
	}
	if task.Workspace != nil {
		ports := ""
		if len(task.Workspace.Ports) > 0 {
			ports = fmt.Sprintf(" (ports %v)", task.Workspace.Ports)
		}
		fmt.Println("  cmux       " + task.Workspace.Title + ports)
	}
	status := fmt.Sprintf("%d changed · ↑%d ↓%d", task.Dirty, task.Ahead, task.Behind)
	if task.Merged {
		status += " · merged"
	}
	if task.Gone {
		status += " · upstream gone"
	}
	fmt.Println("  status     " + status)
	if task.Note != "" {
		fmt.Println("  note       " + task.Note)
	}
	if len(detail.Changes) > 0 {
		fmt.Println("\n" + bold("Changes"))
		for index, change := range detail.Changes {
			if index == 10 {
				fmt.Printf("  … %d more\n", len(detail.Changes)-10)
				break
			}
			fmt.Println("  " + change)
		}
	}
	if len(detail.Log) > 0 {
		fmt.Println("\n" + bold("Commits"))
		for _, line := range detail.Log {
			fmt.Println("  " + line)
		}
	}
	fmt.Println("\n" + bold("Claude sessions"))
	if len(task.Sessions) == 0 {
		fmt.Println(dim("  none yet — wk open starts one"))
	}
	for _, session := range task.Sessions {
		fmt.Println("  " + sessionLine(session))
	}
}

func printOpen(result core.OpenResult) {
	if result.Action == "printed" {
		fmt.Println(yellow(result.Message))
		fmt.Println("  " + result.Command)
		return
	}
	fmt.Println(green("✓ ") + result.Message)
}

// progressFor prints steps to stderr (human) or NDJSON events to stderr (--json keeps stdout clean).
func progressFor(command *cli) core.Progress {
	return stderrProgress{json: *command.json}
}

type stderrProgress struct{ json bool }

func (progress stderrProgress) emit(level, format string, args ...any) {
	message := fmt.Sprintf(format, args...)
	if progress.json {
		data, _ := json.Marshal(map[string]string{"event": "progress", "level": level, "message": message})
		fmt.Fprintln(os.Stderr, string(data))
		return
	}
	prefix := dim("› ")
	if level == "warn" {
		prefix = yellow("! ")
	}
	fmt.Fprintln(os.Stderr, prefix+message)
}

func (progress stderrProgress) Step(format string, args ...any) {
	progress.emit("step", format, args...)
}
func (progress stderrProgress) Warn(format string, args ...any) {
	progress.emit("warn", format, args...)
}

func truncate(text string, max int) string {
	runes := []rune(text)
	if len(runes) <= max {
		return text
	}
	return string(runes[:max-1]) + "…"
}

func ago(moment time.Time) string {
	if moment.IsZero() {
		return "-"
	}
	elapsed := time.Since(moment)
	switch {
	case elapsed < time.Minute:
		return "now"
	case elapsed < time.Hour:
		return fmt.Sprintf("%dm", int(elapsed.Minutes()))
	case elapsed < 24*time.Hour:
		return fmt.Sprintf("%dh", int(elapsed.Hours()))
	case elapsed < 60*24*time.Hour:
		return fmt.Sprintf("%dd", int(elapsed.Hours()/24))
	}
	return fmt.Sprintf("%dmo", int(elapsed.Hours()/24/30))
}
