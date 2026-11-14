package core

import (
	"os"
	"path/filepath"
	"strings"
	"sync"

	"wk/internal/claudeidx"
	"wk/internal/cmux"
	"wk/internal/config"
	"wk/internal/gitops"
	"wk/internal/gitscan"
	"wk/internal/state"
)

// Service is the single entry point used by the CLI and the app.
type Service struct {
	Config config.Config
	State  *state.State
	Index  *claudeidx.Index
	Git    gitscan.Git
	Ops    gitops.Ops
	Cmux   CmuxClient

	mutex       sync.Mutex
	indexDirty  bool
	allSessions []Session // every session under the roots, from the last Snapshot

	baseMutex    sync.Mutex
	detectedBase map[string]string

	cachedScans      []*repoScan
	cachedWorkspaces []cmux.Workspace
	cmuxErr          error
	haveWorkspaces   bool
}

// CmuxClient is the subset of cmux used by core (faked in tests).
type CmuxClient interface {
	Workspaces() ([]cmux.Workspace, error)
	Select(workspace string) error
	Close(workspace string) error
	Activate()
	Installed() bool
	FocusSurface(workspace, surfaceID string) error
	CreateWorkspace(name, cwd, command, layout string) (string, error)
	NewSurface(workspace, command string) error
}

func New() (*Service, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	st, err := state.Load()
	if err != nil {
		return nil, err
	}
	git := gitscan.NewGit(cfg.GitBin)
	labelStripPrefixes = cfg.LabelStripPrefixes
	return &Service{
		Config: cfg,
		State:  st,
		Index:  claudeidx.LoadCache(indexPath()),
		Git:    git,
		Ops:    gitops.Ops{Git: git},
		Cmux:   cmux.New(cfg.CmuxBin),
	}, nil
}

func indexPath() string { return filepath.Join(config.CacheDir(), "index.json") }

// RefreshIndex re-reads changed transcripts and persists the cache.
func (service *Service) RefreshIndex() (claudeidx.Stats, error) {
	stats, err := service.Index.Build(config.Expand(service.Config.ClaudeDir))
	if err != nil {
		return stats, err
	}
	if stats.Parsed > 0 || stats.Files != stats.Reused || service.indexDirty {
		service.indexDirty = false
		return stats, service.Index.SaveCache(indexPath())
	}
	return stats, nil
}

func (service *Service) roots() []string {
	roots := make([]string, 0, len(service.Config.Roots))
	for _, root := range service.Config.Roots {
		roots = append(roots, canonical(config.Expand(root)))
	}
	return roots
}

// canonical resolves symlinks (e.g. /var -> /private/var) so paths from git, cmux and
// Claude transcripts compare equal. Missing paths are cleaned but left as-is.
func canonical(path string) string {
	if path == "" {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	parent, base := filepath.Split(filepath.Clean(path))
	if resolved, err := filepath.EvalSymlinks(parent); err == nil && parent != "" {
		return filepath.Join(resolved, base)
	}
	return filepath.Clean(path)
}

// inRoots reports whether path is inside one of the configured scan roots.
func (service *Service) inRoots(path string) bool {
	for _, root := range service.roots() {
		if path == root || strings.HasPrefix(path, root+"/") {
			return true
		}
	}
	return false
}

func (service *Service) repoName(path string) string {
	for _, root := range service.roots() {
		if rel, err := filepath.Rel(root, path); err == nil && !strings.HasPrefix(rel, "..") {
			return rel
		}
	}
	return filepath.Base(path)
}

// labelStripPrefixes comes from config (label_strip_prefixes).
var labelStripPrefixes []string

// RepoLabel turns a repo directory into a short workspace label (acme-widget -> WIDGET with
// label_strip_prefixes = ["acme-"]).
func RepoLabel(path string) string {
	base := filepath.Base(path)
	for _, prefix := range labelStripPrefixes {
		if trimmed := strings.TrimPrefix(base, prefix); trimmed != base && trimmed != "" {
			base = trimmed
			break
		}
	}
	return strings.ToUpper(base)
}

// repoSettings returns a repo's settings with the base branch filled in: per-repo config,
// then the global config, then detected from git (origin/HEAD, then main/master).
func (service *Service) repoSettings(repo string) config.Repo {
	settings := service.Config.RepoFor(repo)
	if settings.BaseBranch != "" {
		return settings
	}
	service.baseMutex.Lock()
	defer service.baseMutex.Unlock()
	if service.detectedBase == nil {
		service.detectedBase = map[string]string{}
	}
	base, ok := service.detectedBase[repo]
	if !ok {
		base = service.Git.DefaultBranch(repo)
		service.detectedBase[repo] = base
	}
	settings.BaseBranch = base
	return settings
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// SaveState persists pins/notes/aliases.
func (service *Service) SaveState() error { return service.State.Save() }
