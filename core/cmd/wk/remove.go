package main

import (
	"fmt"
	"sort"
	"strings"

	"wk/internal/core"
)

var optionLabels = map[string]string{
	core.OptCloseWorkspace:   "Close the cmux workspace",
	core.OptSwitchMainToBase: "Switch the main folder to the base branch",
	core.OptRemoveWorktree:   "Remove the worktree folder",
	core.OptDeleteBranch:     "Delete the local branch",
	core.OptDeleteRemote:     "Delete the remote branch (origin)",
	core.OptTrashSessions:    "Move its Claude sessions to trash (restorable)",
}

var optionOrder = []string{
	core.OptCloseWorkspace, core.OptSwitchMainToBase, core.OptRemoveWorktree,
	core.OptDeleteBranch, core.OptDeleteRemote, core.OptTrashSessions,
}

func cmdRemove(service *core.Service, args []string) error {
	command := newCLI("remove")
	planOnly := command.set.Bool("plan", false, "only show what would happen")
	keepWorkspace := command.set.Bool("keep-workspace", false, "do not close the cmux workspace")
	keepWorktree := command.set.Bool("keep-worktree", false, "do not remove the worktree folder")
	keepBranch := command.set.Bool("keep-branch", false, "do not delete the local branch")
	remote := command.set.Bool("remote", false, "also delete origin/<branch>")
	sessions := command.set.Bool("sessions", false, "also move sessions to trash")
	confirm := command.set.String("confirm", "", "branch name, required when work would be lost")
	yes := command.set.Bool("yes", false, "do not ask for confirmation")
	if err := command.parse(args); err != nil {
		return err
	}
	query, err := command.arg(0, "task")
	if err != nil {
		return err
	}
	plan, err := service.PlanRemove(query)
	if err != nil {
		return err
	}
	if *planOnly {
		return command.output(plan, func() { printPlan(plan) })
	}
	options := map[string]bool{}
	for key, option := range plan.Options {
		options[key] = option.Default && option.Available
	}
	// `wk rm` names the task explicitly, so it removes the folder and branch unless told to keep
	// them; the typed confirmation below still guards lost work. (The app pre-ticks only safe steps.)
	for _, key := range []string{core.OptRemoveWorktree, core.OptDeleteBranch} {
		options[key] = plan.Options[key].Available
	}
	setIf := func(flagValue bool, key string, value bool) {
		if flagValue {
			options[key] = value && plan.Options[key].Available
		}
	}
	setIf(*keepWorkspace, core.OptCloseWorkspace, false)
	setIf(*keepWorktree, core.OptRemoveWorktree, false)
	setIf(*keepBranch, core.OptDeleteBranch, false)
	setIf(*remote, core.OptDeleteRemote, true)
	setIf(*sessions, core.OptTrashSessions, true)
	if *remote && !plan.Options[core.OptDeleteRemote].Available {
		return fmt.Errorf("cannot delete remote: %s", plan.Options[core.OptDeleteRemote].Reason)
	}

	request := core.RemoveRequest{Task: plan.Task.ID, Options: options, Confirm: *confirm}
	if !*command.json && !*yes {
		printPlan(plan)
		if plan.Blocked != "" {
			return fmt.Errorf("%s", plan.Blocked)
		}
		fmt.Println("\nWill do:")
		any := false
		for _, key := range optionOrder {
			if options[key] {
				fmt.Println("  • " + optionLabels[key])
				any = true
			}
		}
		if !any {
			return fmt.Errorf("nothing selected")
		}
		lossy := options[core.OptRemoveWorktree] && plan.Facts.Dirty > 0 || options[core.OptDeleteBranch] && plan.Facts.Unpushed > 0
		if lossy && request.Confirm == "" {
			answer, err := prompt(red("Work will be lost. Type the branch name to confirm: "))
			if err != nil {
				return err
			}
			request.Confirm = answer
		} else if !lossy {
			answer, err := prompt("Proceed? [y/N] ")
			if err != nil {
				return err
			}
			if !strings.EqualFold(answer, "y") && !strings.EqualFold(answer, "yes") {
				return errCancelled
			}
		}
	}
	results, err := service.ApplyRemove(request, progressFor(command))
	if err != nil {
		return err
	}
	return command.output(results, func() { printSteps(results) })
}

func printPlan(plan core.RemovePlan) {
	task, facts := plan.Task, plan.Facts
	fmt.Printf("%s  %s\n", bold(task.RepoLabel+" "+task.Branch), dim(task.Path))
	fact := func(label, value string, warn bool) {
		if warn {
			value = yellow(value)
		}
		fmt.Printf("  %-22s %s\n", label, value)
	}
	fact("uncommitted changes", fmt.Sprint(facts.Dirty), facts.Dirty > 0)
	fact("unpushed commits", fmt.Sprint(facts.Unpushed), facts.Unpushed > 0)
	fact("on origin", yesNo(facts.HasRemote), false)
	fact("merged into base", yesNo(facts.Merged), false)
	fact("claude sessions", fmt.Sprintf("%d (%d running)", facts.Sessions, facts.LiveSessions), facts.LiveSessions > 0)
	workspace := "no"
	if facts.Workspace != nil {
		workspace = facts.Workspace.Title
	}
	fact("cmux workspace", workspace, false)
	fmt.Println("\nOptions:")
	keys := make([]string, 0, len(plan.Options))
	for key := range plan.Options {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(left, right int) bool {
		return indexOf(optionOrder, keys[left]) < indexOf(optionOrder, keys[right])
	})
	for _, key := range keys {
		option := plan.Options[key]
		box := "[ ]"
		if option.Default && option.Available {
			box = "[x]"
		}
		line := fmt.Sprintf("  %s %s", box, optionLabels[key])
		if !option.Available {
			line = dim(fmt.Sprintf("  [-] %s", optionLabels[key]))
		}
		if option.Reason != "" {
			line += dim(" — " + option.Reason)
		}
		fmt.Println(line)
	}
	if plan.Blocked != "" {
		fmt.Println(red("\nBlocked: " + plan.Blocked))
	}
}

func printSteps(results []core.StepResult) {
	for _, step := range results {
		if step.OK {
			fmt.Println(green("✓ ") + step.Message)
		} else {
			fmt.Println(red("✗ ") + step.Step + ": " + step.Message)
		}
	}
}

func cmdCleanup(service *core.Service, args []string) error {
	command := newCLI("cleanup")
	apply := command.set.Bool("apply", false, "remove the given ids")
	allSafe := command.set.Bool("all-safe", false, "remove every item that loses nothing")
	force := command.set.Bool("force", false, "also remove items with unpushed/uncommitted work")
	if err := command.parse(args); err != nil {
		return err
	}
	items, err := service.Cleanup()
	if err != nil {
		return err
	}
	if !*apply && !*allSafe {
		return command.output(items, func() {
			if len(items) == 0 {
				fmt.Println(green("✓ nothing to clean up"))
				return
			}
			for _, item := range items {
				safety := green("safe")
				if !item.Safe {
					safety = yellow(fmt.Sprintf("%d dirty, %d unpushed", item.Dirty, item.Unpushed))
				}
				fmt.Printf("%-18s %-40s %s  %s\n", string(item.Kind), truncate(item.Title, 40), safety, dim(item.Reason))
				fmt.Printf("%-18s %s\n", "", dim(item.ID))
			}
			fmt.Println(dim("\nwk cleanup --all-safe            remove everything marked safe"))
			fmt.Println(dim("wk cleanup --apply <id> [<id>…]  remove specific items (add --force for unsafe ones)"))
		})
	}
	ids := command.args
	if *allSafe {
		for _, item := range items {
			if item.Safe {
				ids = append(ids, item.ID)
			}
		}
	}
	if len(ids) == 0 {
		return command.output([]core.StepResult{}, func() { fmt.Println("nothing selected") })
	}
	if !*command.json {
		fmt.Printf("Removing %d item(s) (worktree + local branch; remote branches are kept).\n", len(ids))
		answer, err := prompt("Proceed? [y/N] ")
		if err != nil {
			return err
		}
		if !strings.EqualFold(answer, "y") {
			return errCancelled
		}
	}
	results, err := service.ApplyCleanup(ids, *force, progressFor(command))
	if err != nil {
		return err
	}
	return command.output(results, func() { printSteps(results) })
}

func indexOf(list []string, item string) int {
	for index, value := range list {
		if value == item {
			return index
		}
	}
	return len(list)
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}
