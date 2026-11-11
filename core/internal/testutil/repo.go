// Package testutil builds throwaway git repositories for tests.
package testutil

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Repo creates <tmp>/root/<name> with a "production" branch, an origin remote, and one commit.
func Repo(t *testing.T, name string) (root, repo string) {
	t.Helper()
	base := t.TempDir()
	root = filepath.Join(base, "root")
	repo = filepath.Join(root, name)
	remote := filepath.Join(base, "remote.git")
	Git(t, base, "init", "-q", "--bare", "-b", "production", remote)
	os.MkdirAll(repo, 0o755)
	Git(t, repo, "init", "-q", "-b", "production")
	Git(t, repo, "config", "user.email", "test@example.com")
	Git(t, repo, "config", "user.name", "Test")
	Write(t, repo, "README.md", "hello\n")
	Git(t, repo, "add", ".")
	Git(t, repo, "commit", "-q", "-m", "initial")
	Git(t, repo, "remote", "add", "origin", remote)
	Git(t, repo, "push", "-q", "-u", "origin", "production")
	return root, repo
}

func Git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func Write(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// Commit writes a file and commits it on the current branch.
func Commit(t *testing.T, dir, name, message string) {
	t.Helper()
	Write(t, dir, name, message+"\n")
	Git(t, dir, "add", name)
	Git(t, dir, "commit", "-q", "-m", message)
}
