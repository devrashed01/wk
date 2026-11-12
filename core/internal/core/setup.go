package core

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"wk/internal/config"

	"wk/internal/cmux"
)

// Progress receives human-readable updates from long-running actions.
type Progress interface {
	Step(format string, args ...any)
	Warn(format string, args ...any)
}

type NopProgress struct{}

func (NopProgress) Step(string, ...any) {}
func (NopProgress) Warn(string, ...any) {}

// PrepareWorktree copies local env files into a new worktree and returns the shell setup
// command (e.g. "yarn install") to run in the workspace's server pane before the server starts.
// Running it in the terminal gives it the user's full shell environment (nvm, PATH) and visible output.
func (service *Service) PrepareWorktree(repo, path string, progress Progress) string {
	copied, err := copyEnvFiles(repo, path)
	if err != nil {
		progress.Warn("Copying env files failed: %v", err)
	}
	if len(copied) > 0 {
		progress.Step("Copied %s", strings.Join(copied, ", "))
	}
	settings := service.repoSettings(repo)
	if len(settings.PostWorktree) > 0 {
		return strings.Join(settings.PostWorktree, " && ")
	}
	return DetectInstall(path)
}

// DetectInstall picks the package-manager install command from lockfiles.
func DetectInstall(path string) string {
	switch {
	case exists(filepath.Join(path, "yarn.lock")):
		return "yarn install"
	case exists(filepath.Join(path, "pnpm-lock.yaml")):
		return "pnpm install"
	case exists(filepath.Join(path, "package-lock.json")):
		return "npm install"
	}
	return ""
}

// copyEnvFiles copies untracked .env* files from the main repo that the worktree lacks.
func copyEnvFiles(repo, path string) ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(repo, ".env*"))
	if err != nil {
		return nil, err
	}
	var copied []string
	for _, source := range matches {
		info, err := os.Stat(source)
		if err != nil || info.IsDir() {
			continue
		}
		target := filepath.Join(path, filepath.Base(source))
		if exists(target) {
			continue
		}
		if err := copyFile(source, target, info.Mode()); err != nil {
			return copied, fmt.Errorf("%s: %w", filepath.Base(source), err)
		}
		copied = append(copied, filepath.Base(source))
	}
	return copied, nil
}

func copyFile(source, target string, mode os.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(output, input); err != nil {
		output.Close()
		return err
	}
	return output.Close()
}

// joinCommands chains non-empty shell commands with &&.
func joinCommands(commands ...string) string {
	var parts []string
	for _, command := range commands {
		if strings.TrimSpace(command) != "" {
			parts = append(parts, command)
		}
	}
	return strings.Join(parts, " && ")
}

// layoutFor is the repo's own layout, else the global one, else the default.
func (service *Service) layoutFor(settings config.Repo) config.Layout {
	switch {
	case settings.Layout != nil:
		return settings.Layout.Normalized()
	case service.Config.Layout != nil:
		return service.Config.Layout.Normalized()
	}
	return config.DefaultLayout()
}

var paneNames = map[string]string{"claude": "Claude", "server": "Server", "setup": "Setup", "shell": "Terminal"}

// paneSpecs turns a layout into named commands. A new worktree's setup command runs in the
// setup pane when there is one, else ahead of the server, else in the first plain pane, else
// ahead of Claude, so it always runs exactly once.
func paneSpecs(layout config.Layout, claudeCmd, setupCmd, serverCmd string) []cmux.PaneSpec {
	specs := make([]cmux.PaneSpec, len(layout.Panes))
	for index, pane := range layout.Panes {
		spec := cmux.PaneSpec{Name: pane.Name}
		switch pane.Kind {
		case "claude":
			spec.Command = claudeCmd
		case "server":
			spec.Command = serverCmd
		case "command":
			spec.Command = pane.Command
			if spec.Name == "" {
				spec.Name, _, _ = strings.Cut(strings.TrimSpace(pane.Command), " ")
			}
		}
		if spec.Name == "" {
			spec.Name = paneNames[pane.Kind]
		}
		if spec.Name == "" {
			spec.Name = "Terminal"
		}
		specs[index] = spec
	}
	if setupCmd == "" {
		return specs
	}
	for _, kind := range []string{"setup", "server", "shell", "command", "claude"} {
		for index, pane := range layout.Panes {
			if pane.Kind == kind {
				specs[index].Command = joinCommands(setupCmd, specs[index].Command)
				return specs
			}
		}
	}
	specs[0].Command = joinCommands(setupCmd, specs[0].Command)
	return specs
}
