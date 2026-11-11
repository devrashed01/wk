// Package config loads and saves ~/.config/wk/config.toml.
package config

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// Repo holds per-repository settings, keyed by the main repo path (with ~).
type Repo struct {
	ServerCmd    string   `toml:"server_cmd,omitempty" json:"server_cmd,omitempty"`
	BaseBranch   string   `toml:"base_branch,omitempty" json:"base_branch,omitempty"`
	PostWorktree []string `toml:"post_worktree,omitempty" json:"post_worktree,omitempty"`
	NoLayout     bool     `toml:"no_layout,omitempty" json:"no_layout,omitempty"`
}

type Config struct {
	Roots      []string `toml:"roots" json:"roots"`
	BaseBranch string   `toml:"base_branch" json:"base_branch"`
	RecentDays int      `toml:"recent_days" json:"recent_days"`
	ClaudeDir  string   `toml:"claude_dir" json:"claude_dir"`
	CmuxBin    string   `toml:"cmux_bin,omitempty" json:"cmux_bin,omitempty"`
	GitBin     string   `toml:"git_bin,omitempty" json:"git_bin,omitempty"`
	Hotkey     string   `toml:"hotkey,omitempty" json:"hotkey,omitempty"`
	// AutoStartClaude runs claude (fresh or --resume) right away when opening a workspace; by default
	// the command is only typed at the prompt, since resuming re-reads the whole transcript and costs tokens.
	AutoStartClaude bool `toml:"auto_start_claude,omitempty" json:"auto_start_claude,omitempty"`
	// LabelStripPrefixes are removed from repo folder names for short labels ("acme-web" -> "WEB").
	LabelStripPrefixes []string        `toml:"label_strip_prefixes,omitempty" json:"label_strip_prefixes,omitempty"`
	Repos              map[string]Repo `toml:"repo,omitempty" json:"repos,omitempty"`
}

// DefaultRoots are the usual places people keep code; missing ones are skipped.
var DefaultRoots = []string{"~/code", "~/Code", "~/projects", "~/Projects", "~/Developer", "~/dev", "~/src", "~/repos", "~/work", "~/git", "~/GitHub"}

func Defaults() Config {
	return Config{
		Roots:      DefaultRoots,
		BaseBranch: "", // empty = detect per repo (origin/HEAD, then main/master)
		RecentDays: 30,
		ClaudeDir:  "~/.claude",
		Hotkey:     "option+space",
		Repos:      map[string]Repo{},
	}
}

// Path returns the config file location (WK_CONFIG overrides).
func Path() string {
	if p := os.Getenv("WK_CONFIG"); p != "" {
		return p
	}
	return Expand("~/.config/wk/config.toml")
}

// Load reads the config, filling defaults for missing values. A missing file is not an error.
func Load() (Config, error) {
	cfg := Defaults()
	data, err := os.ReadFile(Path())
	if os.IsNotExist(err) {
		return cfg, nil
	}
	if err != nil {
		return cfg, err
	}
	if _, err := toml.Decode(string(data), &cfg); err != nil {
		return cfg, err
	}
	if cfg.Repos == nil {
		cfg.Repos = map[string]Repo{}
	}
	if cfg.RecentDays <= 0 {
		cfg.RecentDays = 30
	}
	if cfg.ClaudeDir == "" {
		cfg.ClaudeDir = "~/.claude"
	}
	return cfg, nil
}

func Save(cfg Config) error {
	path := Path()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	file, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := toml.NewEncoder(file).Encode(cfg); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// RepoFor returns settings for a main repo path, merged with global defaults.
func (cfg Config) RepoFor(repoPath string) Repo {
	repo := cfg.Repos[Collapse(repoPath)]
	if repo.BaseBranch == "" {
		repo.BaseBranch = cfg.BaseBranch
	}
	return repo
}

// Expand replaces a leading ~ with the home directory.
func Expand(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(path, "~"))
	}
	return path
}

// Collapse replaces the home directory prefix with ~.
func Collapse(path string) string {
	home, _ := os.UserHomeDir()
	if path == home {
		return "~"
	}
	if strings.HasPrefix(path, home+"/") {
		return "~" + strings.TrimPrefix(path, home)
	}
	return path
}

// StateDir is where wk keeps pins, notes, trash (WK_STATE_DIR overrides).
func StateDir() string {
	if p := os.Getenv("WK_STATE_DIR"); p != "" {
		return p
	}
	return Expand("~/.local/state/wk")
}

// CacheDir holds the transcript index (WK_CACHE_DIR overrides).
func CacheDir() string {
	if p := os.Getenv("WK_CACHE_DIR"); p != "" {
		return p
	}
	return Expand("~/.cache/wk")
}
