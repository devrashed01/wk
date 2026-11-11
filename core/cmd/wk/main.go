// Command wk switches between repos, branches, worktrees and Claude Code sessions.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"wk/internal/core"
)

const usage = `wk — workspace manager for repos, branches, worktrees and Claude sessions

Just run "wk" to open the picker (or the Wk app's search window when installed).

Everyday
  wk                         open the picker / app
  wk tasks [--all]           list tasks (repo + branch) with status
  wk open <task>             jump to a task (resumes its Claude session)
       --session <id>  --new (fresh Claude)  --no-claude  --via switch|worktree  --new-workspace
  wk sessions [words...]     search every Claude session  (--trash includes trashed)
  wk resume <session>        open a session where it lives  (--recreate, --new-workspace)
  wk new [name]              create a branch / worktree and open it (asks what it needs)
       --repo <r> --from base|local|remote|worktree --ref <x> --in-place --stash --no-setup --no-open

Branches & worktrees
  wk show <task>             details: status, commits, sessions
  wk switch <task> <branch>  check out another branch in that task's folder  (--stash)
  wk rename-branch <task> <new>
  wk pull <task>
  wk worktree <repo> <branch> [--new <name>] [--base <ref>]

Remove & clean up
  wk remove <task>           shows what will happen, asks before doing it
       --plan  --keep-workspace --keep-worktree --keep-branch --remote --sessions --confirm <branch> --yes
  wk cleanup                 suggest merged / gone / stale / orphaned items  (--apply <id>... | --all-safe, --force)

Organize
  wk pin|unpin|hide|unhide <task>     wk note <task> [text]
  wk session-rename <id> <name>       wk trash <id>      wk restore <id>

Setup
  wk config [get|path|edit]   wk index   wk serve (used by the app)

<task> can be a ticket (ABC-123 or 123), part of a branch name, or a full id.
Add --json to any command for machine-readable output.
`

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "wk:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return launchDefault()
	}
	command, rest := args[0], args[1:]
	if command == "help" || command == "-h" || command == "--help" {
		fmt.Print(usage)
		return nil
	}
	if command == "serve" {
		return serve()
	}
	service, err := core.New()
	if err != nil {
		return err
	}
	handler, ok := commands[command]
	if !ok {
		return fmt.Errorf("unknown command %q (run wk help)", command)
	}
	return handler(service, rest)
}

// cli wraps a flag set that also accepts flags after positional arguments.
type cli struct {
	set  *flag.FlagSet
	json *bool
	args []string
}

func newCLI(name string) *cli {
	set := flag.NewFlagSet(name, flag.ContinueOnError)
	set.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	return &cli{set: set, json: set.Bool("json", false, "JSON output")}
}

func (command *cli) parse(args []string) error {
	var flags, positional []string
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if arg == "--" {
			positional = append(positional, args[index+1:]...)
			break
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			positional = append(positional, arg)
			continue
		}
		flags = append(flags, arg)
		name := strings.TrimLeft(arg, "-")
		if strings.Contains(name, "=") {
			continue
		}
		if definition := command.set.Lookup(name); definition != nil {
			if boolean, ok := definition.Value.(interface{ IsBoolFlag() bool }); ok && boolean.IsBoolFlag() {
				continue
			}
			if index+1 < len(args) {
				index++
				flags = append(flags, args[index])
			}
		}
	}
	if err := command.set.Parse(flags); err != nil {
		return err
	}
	command.args = positional
	return nil
}

func (command *cli) arg(index int, name string) (string, error) {
	if index < len(command.args) {
		return command.args[index], nil
	}
	return "", fmt.Errorf("missing <%s>", name)
}

func printJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

// output prints JSON in --json mode, otherwise calls the human formatter.
func (command *cli) output(value any, human func()) error {
	if *command.json {
		return printJSON(value)
	}
	human()
	return nil
}

// launchDefault opens the app's palette when Wk.app is installed, else the terminal picker.
func launchDefault() error {
	if os.Getenv("WK_NO_APP") == "" && appInstalled() {
		return exec.Command("open", "wk://palette").Run()
	}
	service, err := core.New()
	if err != nil {
		return err
	}
	return pick(service)
}

func appInstalled() bool {
	out, err := exec.Command("mdfind", "kMDItemCFBundleIdentifier == 'com.devrashed01.wk'").Output()
	return err == nil && strings.TrimSpace(string(out)) != ""
}

var errCancelled = errors.New("cancelled")
