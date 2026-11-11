package core

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

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

func cmuxLayout(serverCmd, claudeCmd string) string { return cmux.Layout(serverCmd, claudeCmd) }
