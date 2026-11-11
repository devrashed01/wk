package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"wk/internal/config"
	"wk/internal/core"
	"wk/internal/gitops"
)

func hasFzf() bool {
	_, err := exec.LookPath("fzf")
	return err == nil
}

// choose shows "key\tlabel" options in fzf (or a numbered list) and returns the chosen key.
func choose(header string, options []string) (string, error) {
	if len(options) == 0 {
		return "", errors.New("nothing to choose from")
	}
	if hasFzf() {
		cmd := exec.Command("fzf", "--height=40%", "--reverse", "--delimiter=\t", "--with-nth=2..", "--header="+header, "--no-sort")
		cmd.Stdin = strings.NewReader(strings.Join(options, "\n"))
		cmd.Stderr = os.Stderr
		out, err := cmd.Output()
		if err != nil {
			return "", errCancelled
		}
		key, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\t")
		return key, nil
	}
	fmt.Fprintln(os.Stderr, header)
	for index, option := range options {
		_, label, _ := strings.Cut(option, "\t")
		fmt.Fprintf(os.Stderr, "  %d) %s\n", index+1, label)
	}
	answer, err := prompt("Choose a number: ")
	if err != nil {
		return "", err
	}
	var number int
	if _, err := fmt.Sscan(answer, &number); err != nil || number < 1 || number > len(options) {
		return "", errCancelled
	}
	key, _, _ := strings.Cut(options[number-1], "\t")
	return key, nil
}

var stdinReader = bufio.NewReader(os.Stdin)

func prompt(question string) (string, error) {
	fmt.Fprint(os.Stderr, question)
	line, err := stdinReader.ReadString('\n')
	if err != nil && line == "" {
		return "", errCancelled
	}
	return strings.TrimSpace(line), nil
}

// completeNewRequest asks for anything wk new was not given.
func completeNewRequest(service *core.Service, request *core.NewTaskRequest, inPlaceGiven bool) error {
	if request.Repo == "" {
		snapshot, err := service.Snapshot()
		if err != nil {
			return err
		}
		var options []string
		for _, repo := range snapshot.Repos {
			options = append(options, repo.Path+"\t"+repo.Label+"  "+dim(repo.Name))
		}
		if request.Repo, err = choose("Which repo?", options); err != nil {
			return err
		}
	}
	refs, err := service.RepoRefs(request.Repo)
	if err != nil {
		return err
	}
	if request.From == "" && request.Ref == "" {
		choice, err := choose("Start from?", []string{
			"base\tLatest " + refs.BaseBranch + " (recommended for a new feature)",
			"local\tAn existing local branch",
			"remote\tA remote branch (origin/…)",
			"worktree\tWhat is checked out in an existing worktree",
		})
		if err != nil {
			return err
		}
		request.From = core.StartFrom(choice)
		var list []string
		switch request.From {
		case core.FromLocal:
			list = refs.Local
		case core.FromRemote:
			list = refs.Remote
		case core.FromWorktree:
			list = refs.Worktrees
		}
		if len(list) > 0 {
			var options []string
			for _, item := range list {
				options = append(options, item+"\t"+config.Collapse(item))
			}
			if request.Ref, err = choose("Which one?", options); err != nil {
				return err
			}
		}
	}
	if !inPlaceGiven && request.Mode == "" {
		choice, err := choose("Where should it live?", []string{
			"worktree\tNew worktree folder next to the repo (keeps your current work untouched)",
			"in-place\tSwitch the main repo folder to the new branch",
		})
		if err != nil {
			return err
		}
		request.Mode = core.CreateMode(choice)
	}
	for request.Name == "" {
		hint := ""
		if refs.Suggested != "" {
			hint = dim(" (e.g. " + refs.Suggested + "1234-short-description)")
		}
		name, err := prompt("Branch name" + hint + ": ")
		if err != nil {
			return err
		}
		if name == "" {
			continue
		}
		if err := service.Ops.ValidateBranchName(refs.Repo, name); err != nil {
			fmt.Fprintln(os.Stderr, red(err.Error()))
			continue
		}
		request.Name = name
	}
	if request.Mode == core.ModeWorktree {
		fmt.Fprintln(os.Stderr, dim("folder: "+config.Collapse(gitops.WorktreePath(refs.Repo, request.Name))))
	}
	return nil
}

// pick is the terminal picker used when the app is not installed.
func pick(service *core.Service) error {
	if !hasFzf() {
		return cmdTasks(service, nil)
	}
	snapshot, err := service.Snapshot()
	if err != nil {
		return err
	}
	var lines []string
	for _, task := range snapshot.Tasks {
		if !task.Hidden && task.ParentID == "" {
			lines = append(lines, task.ID+"\t"+taskLine(task))
		}
	}
	self, _ := os.Executable()
	header := "enter open · ctrl-n new · ctrl-s sessions · ctrl-x remove · ctrl-p pin · ctrl-l cleanup · esc quit"
	cmd := exec.Command("fzf", "--ansi", "--reverse", "--delimiter=\t", "--with-nth=2..", "--no-sort",
		"--header="+header, "--expect=ctrl-n,ctrl-s,ctrl-x,ctrl-p,ctrl-l",
		"--preview="+self+" show {1}", "--preview-window=down,50%")
	cmd.Stdin = strings.NewReader(strings.Join(lines, "\n"))
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil // esc
	}
	parts := strings.SplitN(string(bytes.TrimRight(out, "\n")), "\n", 2)
	key := parts[0]
	taskID := ""
	if len(parts) > 1 {
		taskID, _, _ = strings.Cut(parts[1], "\t")
	}
	switch key {
	case "ctrl-n":
		return cmdNew(service, nil)
	case "ctrl-s":
		return pickSession(service)
	case "ctrl-x":
		return cmdRemove(service, []string{taskID})
	case "ctrl-p":
		task, err := core.FindTask(snapshot.Tasks, taskID)
		if err != nil {
			return err
		}
		return service.SetPinned(taskID, !task.Pinned)
	case "ctrl-l":
		return cmdCleanup(service, nil)
	}
	if taskID == "" {
		return nil
	}
	return cmdOpen(service, []string{taskID})
}

func pickSession(service *core.Service) error {
	sessions, err := service.Sessions("", false)
	if err != nil {
		return err
	}
	var options []string
	for _, session := range sessions {
		options = append(options, session.ID+"\t"+sessionLine(session))
	}
	id, err := choose("Resume which session? (type to search)", options)
	if err != nil {
		return err
	}
	return cmdResume(service, []string{id})
}
