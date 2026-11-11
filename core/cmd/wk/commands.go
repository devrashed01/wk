package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"wk/internal/config"
	"wk/internal/core"
)

type handler func(service *core.Service, args []string) error

var commands map[string]handler

func init() {
	commands = map[string]handler{
		"tasks":          cmdTasks,
		"show":           cmdShow,
		"open":           cmdOpen,
		"sessions":       cmdSessions,
		"resume":         cmdResume,
		"new":            cmdNew,
		"switch":         cmdSwitch,
		"rename-branch":  cmdRenameBranch,
		"pull":           cmdPull,
		"worktree":       cmdWorktree,
		"remove":         cmdRemove,
		"cleanup":        cmdCleanup,
		"pin":            taskFlag(func(service *core.Service, task string) error { return service.SetPinned(task, true) }, "Pinned"),
		"unpin":          taskFlag(func(service *core.Service, task string) error { return service.SetPinned(task, false) }, "Unpinned"),
		"hide":           taskFlag(func(service *core.Service, task string) error { return service.SetHidden(task, true) }, "Hidden"),
		"unhide":         taskFlag(func(service *core.Service, task string) error { return service.SetHidden(task, false) }, "Unhidden"),
		"note":           cmdNote,
		"session-rename": cmdSessionRename,
		"trash":          cmdTrash,
		"restore":        cmdRestore,
		"config":         cmdConfig,
		"index":          cmdIndex,
		"pick":           func(service *core.Service, _ []string) error { return pick(service) },
	}
}

func cmdTasks(service *core.Service, args []string) error {
	command := newCLI("tasks")
	all := command.set.Bool("all", false, "include hidden tasks")
	if err := command.parse(args); err != nil {
		return err
	}
	snapshot, err := service.Snapshot()
	if err != nil {
		return err
	}
	if *command.json {
		return printJSON(snapshot)
	}
	if !snapshot.CmuxRunning {
		fmt.Println(dim("cmux is not running — open/new will print commands instead"))
	}
	for _, task := range snapshot.Tasks {
		if (task.Hidden || task.ParentID != "") && !*all {
			continue
		}
		fmt.Println(taskLine(task))
	}
	fmt.Printf("\n%d tasks · %d open · %s running · %s waiting for you\n",
		snapshot.Counts.Tasks, snapshot.Counts.Open, bold(fmt.Sprint(snapshot.Counts.Running)), bold(fmt.Sprint(snapshot.Counts.Waiting)))
	return nil
}

func cmdShow(service *core.Service, args []string) error {
	command := newCLI("show")
	if err := command.parse(args); err != nil {
		return err
	}
	query, err := command.arg(0, "task")
	if err != nil {
		return err
	}
	detail, err := service.Show(query)
	if err != nil {
		return err
	}
	return command.output(detail, func() { printDetail(detail) })
}

func cmdOpen(service *core.Service, args []string) error {
	command := newCLI("open")
	session := command.set.String("session", "", "session id to resume")
	fresh := command.set.Bool("new", false, "start a fresh Claude session")
	noClaude := command.set.Bool("no-claude", false, "open without Claude")
	via := command.set.String("via", "", "switch|worktree for branches without a folder")
	stash := command.set.Bool("stash", false, "stash uncommitted changes when switching")
	newWorkspace := command.set.Bool("new-workspace", false, "always open a new cmux workspace")
	if err := command.parse(args); err != nil {
		return err
	}
	query, err := command.arg(0, "task")
	if err != nil {
		return err
	}
	request := core.OpenRequest{Task: query, Session: *session, Via: core.CheckoutVia(*via), Stash: *stash, NewWorkspace: *newWorkspace}
	switch {
	case *noClaude:
		request.Mode = core.OpenNone
	case *fresh:
		request.Mode = core.OpenNew
	}
	result, err := service.Open(request, progressFor(command))
	if err == core.ErrNeedsCheckout && !*command.json {
		choice, chooseErr := choose("This branch has no folder. How do you want to open it?", []string{
			"worktree\tCreate a new sibling worktree folder (recommended)",
			"switch\tSwitch the main repo folder to this branch",
		})
		if chooseErr != nil {
			return chooseErr
		}
		request.Via = core.CheckoutVia(choice)
		result, err = service.Open(request, progressFor(command))
	}
	if err != nil {
		return err
	}
	return command.output(result, func() { printOpen(result) })
}

func cmdSessions(service *core.Service, args []string) error {
	command := newCLI("sessions")
	trash := command.set.Bool("trash", false, "include trashed sessions")
	limit := command.set.Int("limit", 40, "max rows (0 = all)")
	if err := command.parse(args); err != nil {
		return err
	}
	sessions, err := service.Sessions(strings.Join(command.args, " "), *trash)
	if err != nil {
		return err
	}
	return command.output(sessions, func() {
		for index, session := range sessions {
			if *limit > 0 && index >= *limit {
				fmt.Printf(dim("… %d more (use --limit 0)\n"), len(sessions)-index)
				break
			}
			fmt.Println(sessionLine(session))
		}
	})
}

func cmdResume(service *core.Service, args []string) error {
	command := newCLI("resume")
	newWorkspace := command.set.Bool("new-workspace", false, "always open a new cmux workspace")
	recreate := command.set.Bool("recreate", false, "recreate a deleted worktree at its original path")
	if err := command.parse(args); err != nil {
		return err
	}
	id, err := command.arg(0, "session")
	if err != nil {
		return err
	}
	result, err := service.Resume(core.ResumeRequest{Session: id, NewWorkspace: *newWorkspace, Recreate: *recreate}, progressFor(command))
	if err != nil {
		return err
	}
	return command.output(result, func() { printOpen(result) })
}

func cmdNew(service *core.Service, args []string) error {
	command := newCLI("new")
	repo := command.set.String("repo", "", "repo path or name (frontend/admin)")
	from := command.set.String("from", "", "base|local|remote|worktree")
	ref := command.set.String("ref", "", "start branch / remote branch / worktree path")
	inPlace := command.set.Bool("in-place", false, "switch an existing folder instead of creating a worktree")
	target := command.set.String("target", "", "in-place: which worktree folder to switch (default main)")
	stash := command.set.Bool("stash", false, "stash uncommitted changes (in-place)")
	noSetup := command.set.Bool("no-setup", false, "skip env copy and install")
	noOpen := command.set.Bool("no-open", false, "do not open a cmux workspace")
	noClaude := command.set.Bool("no-claude", false, "open without starting Claude")
	if err := command.parse(args); err != nil {
		return err
	}
	request := core.NewTaskRequest{
		Repo: *repo, From: core.StartFrom(*from), Ref: *ref, Target: *target, Stash: *stash, NoOpen: *noOpen,
	}
	if len(command.args) > 0 {
		request.Name = command.args[0]
	}
	if *inPlace {
		request.Mode = core.ModeInPlace
	}
	if *noSetup {
		setup := false
		request.Setup = &setup
	}
	if *noClaude {
		request.Open = core.OpenNone
	}
	if !*command.json {
		if err := completeNewRequest(service, &request, *inPlace); err != nil {
			return err
		}
	}
	result, err := service.NewTask(request, progressFor(command))
	if err != nil {
		return err
	}
	return command.output(result, func() {
		fmt.Printf("%s %s (from %s) at %s\n", green("✓ created"), bold(result.Branch), result.Base, config.Collapse(result.Path))
		if result.SetupCmd != "" {
			fmt.Println(dim("  setup runs in the server pane: " + result.SetupCmd))
		}
		if result.Opened != nil {
			printOpen(*result.Opened)
		}
	})
}

func cmdSwitch(service *core.Service, args []string) error {
	command := newCLI("switch")
	stash := command.set.Bool("stash", false, "stash uncommitted changes first")
	if err := command.parse(args); err != nil {
		return err
	}
	task, err := command.arg(0, "task")
	if err != nil {
		return err
	}
	branch, err := command.arg(1, "branch")
	if err != nil {
		return err
	}
	message, err := service.SwitchBranch(task, branch, *stash)
	return messageResult(command, message, err)
}

func cmdRenameBranch(service *core.Service, args []string) error {
	command := newCLI("rename-branch")
	if err := command.parse(args); err != nil {
		return err
	}
	task, err := command.arg(0, "task")
	if err != nil {
		return err
	}
	name, err := command.arg(1, "new-name")
	if err != nil {
		return err
	}
	message, err := service.RenameBranch(task, name)
	return messageResult(command, message, err)
}

func cmdPull(service *core.Service, args []string) error {
	command := newCLI("pull")
	if err := command.parse(args); err != nil {
		return err
	}
	task, err := command.arg(0, "task")
	if err != nil {
		return err
	}
	message, err := service.Pull(task)
	return messageResult(command, message, err)
}

func cmdWorktree(service *core.Service, args []string) error {
	command := newCLI("worktree")
	newName := command.set.String("new", "", "create a new branch with this name")
	base := command.set.String("base", "", "start point for --new (default: <branch>)")
	if err := command.parse(args); err != nil {
		return err
	}
	if len(command.args) > 0 && command.args[0] == "add" {
		command.args = command.args[1:]
	}
	repo, err := command.arg(0, "repo")
	if err != nil {
		return err
	}
	branch, err := command.arg(1, "branch")
	if err != nil {
		return err
	}
	result, err := service.AddWorktree(repo, branch, *newName, *base, progressFor(command))
	if err != nil {
		return err
	}
	return command.output(result, func() {
		fmt.Printf("%s %s at %s\n", green("✓ worktree"), bold(result.Branch), config.Collapse(result.Path))
		fmt.Println(dim("  open it with: wk open " + result.TaskID))
	})
}

func cmdNote(service *core.Service, args []string) error {
	command := newCLI("note")
	if err := command.parse(args); err != nil {
		return err
	}
	task, err := command.arg(0, "task")
	if err != nil {
		return err
	}
	note := strings.Join(command.args[1:], " ")
	return messageResult(command, "Note saved", service.SetNote(task, note))
}

func cmdSessionRename(service *core.Service, args []string) error {
	command := newCLI("session-rename")
	if err := command.parse(args); err != nil {
		return err
	}
	id, err := command.arg(0, "session")
	if err != nil {
		return err
	}
	return messageResult(command, "Renamed (wk only; Claude's files are untouched)", service.RenameSession(id, strings.Join(command.args[1:], " ")))
}

func cmdTrash(service *core.Service, args []string) error {
	command := newCLI("trash")
	if err := command.parse(args); err != nil {
		return err
	}
	id, err := command.arg(0, "session")
	if err != nil {
		return err
	}
	return messageResult(command, "Moved to trash (wk restore "+id+" to undo)", service.TrashSession(id))
}

func cmdRestore(service *core.Service, args []string) error {
	command := newCLI("restore")
	if err := command.parse(args); err != nil {
		return err
	}
	id, err := command.arg(0, "session")
	if err != nil {
		return err
	}
	return messageResult(command, "Restored", service.RestoreSession(id))
}

func cmdConfig(service *core.Service, args []string) error {
	command := newCLI("config")
	if err := command.parse(args); err != nil {
		return err
	}
	action := "get"
	if len(command.args) > 0 {
		action = command.args[0]
	}
	switch action {
	case "path":
		fmt.Println(config.Path())
	case "get":
		return printJSON(service.Config)
	case "edit":
		if _, err := os.Stat(config.Path()); os.IsNotExist(err) {
			if err := config.Save(service.Config); err != nil {
				return err
			}
		}
		editor := os.Getenv("EDITOR")
		if editor == "" {
			editor = "vi"
		}
		cmd := exec.Command("sh", "-c", editor+` "$0"`, config.Path())
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	default:
		return fmt.Errorf("config: unknown action %q (get|path|edit)", action)
	}
	return nil
}

func cmdIndex(service *core.Service, args []string) error {
	command := newCLI("index")
	if err := command.parse(args); err != nil {
		return err
	}
	started := time.Now()
	stats, err := service.RefreshIndex()
	if err != nil {
		return err
	}
	elapsed := time.Since(started)
	return command.output(map[string]any{"stats": stats, "elapsed_ms": elapsed.Milliseconds()}, func() {
		fmt.Printf("%d transcripts · %d parsed · %d cached · %d failed · %s\n", stats.Files, stats.Parsed, stats.Reused, stats.Failures, elapsed.Round(time.Millisecond))
	})
}

func taskFlag(apply func(*core.Service, string) error, done string) handler {
	return func(service *core.Service, args []string) error {
		command := newCLI("task")
		if err := command.parse(args); err != nil {
			return err
		}
		task, err := command.arg(0, "task")
		if err != nil {
			return err
		}
		return messageResult(command, done, apply(service, task))
	}
}

func messageResult(command *cli, message string, err error) error {
	if err != nil {
		return err
	}
	return command.output(map[string]string{"message": message}, func() { fmt.Println(green("✓ ") + message) })
}
