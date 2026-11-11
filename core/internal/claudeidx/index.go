package claudeidx

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
)

const cacheVersion = 2

// Index is the cached set of sessions keyed by transcript path.
type Index struct {
	Version  int                `json:"version"`
	Sessions map[string]Session `json:"sessions"`
}

// Stats reports what a Build call did.
type Stats struct {
	Files    int `json:"files"`
	Parsed   int `json:"parsed"`
	Reused   int `json:"reused"`
	Failures int `json:"failures"`
}

func LoadCache(path string) *Index {
	index := &Index{Version: cacheVersion, Sessions: map[string]Session{}}
	data, err := os.ReadFile(path)
	if err != nil {
		return index
	}
	var cached Index
	if json.Unmarshal(data, &cached) != nil || cached.Version != cacheVersion || cached.Sessions == nil {
		return index
	}
	return &cached
}

func (index *Index) SaveCache(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(index)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Build refreshes the index from claudeDir/projects, re-parsing only changed files.
func (index *Index) Build(claudeDir string) (Stats, error) {
	paths, err := filepath.Glob(filepath.Join(claudeDir, "projects", "*", "*.jsonl"))
	if err != nil {
		return Stats{}, err
	}
	stats := Stats{Files: len(paths)}
	fresh := make(map[string]Session, len(paths))
	var stale []Session
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		cached, ok := index.Sessions[path]
		if ok && cached.Size == info.Size() && cached.ModTime == info.ModTime().UnixNano() {
			fresh[path] = cached
			stats.Reused++
			continue
		}
		cached.Path = path
		stale = append(stale, cached)
	}

	var mutex sync.Mutex
	var group sync.WaitGroup
	jobs := make(chan Session)
	for range runtime.NumCPU() {
		group.Add(1)
		go func() {
			defer group.Done()
			for previous := range jobs {
				session, err := parseFileFrom(previous, previous.Path)
				mutex.Lock()
				if err != nil {
					stats.Failures++
				} else {
					fresh[previous.Path] = session
					stats.Parsed++
				}
				mutex.Unlock()
			}
		}()
	}
	for _, previous := range stale {
		jobs <- previous
	}
	close(jobs)
	group.Wait()

	index.Sessions = fresh
	return stats, nil
}

// Update re-parses a single transcript (used by the watcher). Returns false if unchanged.
func (index *Index) Update(path string) (Session, bool, error) {
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		_, existed := index.Sessions[path]
		delete(index.Sessions, path)
		return Session{}, existed, nil
	}
	if err != nil {
		return Session{}, false, err
	}
	if cached, ok := index.Sessions[path]; ok && cached.Size == info.Size() && cached.ModTime == info.ModTime().UnixNano() {
		return cached, false, nil
	}
	session, err := parseFileFrom(index.Sessions[path], path)
	if err != nil {
		return Session{}, false, err
	}
	index.Sessions[path] = session
	return session, true, nil
}

// List returns sessions that contain at least one prompt, newest first.
func (index *Index) List() []Session {
	sessions := make([]Session, 0, len(index.Sessions))
	for _, session := range index.Sessions {
		if session.Prompts == 0 || session.Cwd == "" {
			continue
		}
		sessions = append(sessions, session)
	}
	sort.Slice(sessions, func(left, right int) bool {
		return sessions[left].Last.After(sessions[right].Last)
	})
	return sessions
}
