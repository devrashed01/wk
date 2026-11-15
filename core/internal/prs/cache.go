package prs

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sync"
	"time"
)

// RepoPRs is what was last fetched for one repo.
type RepoPRs struct {
	Fetched  time.Time     `json:"fetched"`
	Error    string        `json:"error,omitempty"`
	Branches map[string]PR `json:"branches,omitempty"`
}

// Cache keeps PRs per repo on disk so they show at once after a restart. Refresh fetches stale
// repos in the background and rewrites the file only when something changed, which is the
// app's cue to refresh.
type Cache struct {
	Path string
	TTL  time.Duration

	mutex    sync.Mutex
	repos    map[string]RepoPRs
	fetching map[string]bool
	loaded   bool
}

func NewCache(path string) *Cache {
	return &Cache{Path: path, TTL: 3 * time.Minute}
}

func (cache *Cache) load() {
	if cache.loaded {
		return
	}
	cache.loaded = true
	cache.repos = map[string]RepoPRs{}
	cache.fetching = map[string]bool{}
	if data, err := os.ReadFile(cache.Path); err == nil {
		_ = json.Unmarshal(data, &cache.repos)
	}
}

// Get returns the cached PRs of a repo (nil when none yet).
func (cache *Cache) Get(repo string) RepoPRs {
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	cache.load()
	return cache.repos[repo]
}

// Refresh starts a background fetch for each repo whose data is older than the TTL.
// force fetches regardless of age.
func (cache *Cache) Refresh(repos []string, fetcher Fetcher, gitBin string, force bool) {
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	cache.load()
	for _, repo := range repos {
		if cache.fetching[repo] || (!force && time.Since(cache.repos[repo].Fetched) < cache.TTL) {
			continue
		}
		cache.fetching[repo] = true
		go cache.fetch(repo, fetcher, gitBin)
	}
}

func (cache *Cache) fetch(repo string, fetcher Fetcher, gitBin string) {
	result := RepoPRs{Fetched: time.Now()}
	out, err := exec.Command(gitBin, "-C", repo, "remote", "get-url", "origin").Output()
	if remote, ok := ParseRemote(string(out)); err == nil && ok && Supported(remote) {
		branches, err := fetcher.Fetch(repo, remote)
		if err != nil {
			result.Error = err.Error()
			result.Branches = cache.Get(repo).Branches // keep showing the last good data
		} else {
			result.Branches = branches
		}
	}

	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	delete(cache.fetching, repo)
	previous := cache.repos[repo]
	cache.repos[repo] = result
	if previous.Error != result.Error || !reflect.DeepEqual(previous.Branches, result.Branches) {
		cache.save()
	}
}

func (cache *Cache) save() {
	data, err := json.Marshal(cache.repos)
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(cache.Path), 0o755)
	temp := cache.Path + ".tmp"
	if os.WriteFile(temp, data, 0o600) == nil {
		_ = os.Rename(temp, cache.Path)
	}
}

// Wait blocks until no fetch is running (for the CLI and tests), up to timeout.
func (cache *Cache) Wait(timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		cache.mutex.Lock()
		busy := len(cache.fetching) > 0
		cache.mutex.Unlock()
		if !busy {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}
