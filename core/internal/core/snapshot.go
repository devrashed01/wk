package core

import (
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"wk/internal/claudeidx"
	"wk/internal/cmux"
	"wk/internal/config"
	"wk/internal/gitops"
	"wk/internal/gitscan"
)

const (
	snapshotSessionDays  = 60
	snapshotSessionLimit = 300
	maxRepoDepth         = 3
)

// Base branch names never shown as their own task unless checked out or pinned.
var conventionalBases = []string{"production", "staging", "development", "master", "main", "develop"}

type repoScan struct {
	repo      Repo
	branches  []gitscan.Branch
	merged    map[string]bool
	dirty     map[string]int // worktree path -> changed paths
	localSet  map[string]bool
	worktrees []gitscan.Worktree
}

// Scope says which inputs changed; untouched inputs are reused from the previous snapshot.
type Scope struct {
	Git  bool `json:"git"`  // branches, worktrees, dirty state
	Cmux bool `json:"cmux"` // open workspaces
	// Sessions (transcripts + cmux hook state) are always refreshed: it is cheap and incremental.
}

var FullScope = Scope{Git: true, Cmux: true}

// Snapshot builds the full picture: repos, tasks, sessions, live cmux status.
func (service *Service) Snapshot() (Snapshot, error) { return service.SnapshotScoped(FullScope) }

// SnapshotScoped rebuilds only what changed. A transcript-only change costs a few milliseconds.
func (service *Service) SnapshotScoped(scope Scope) (Snapshot, error) {
	service.mutex.Lock()
	defer service.mutex.Unlock()
	if _, err := service.RefreshIndex(); err != nil {
		return Snapshot{}, err
	}
	if scope.Git || service.cachedScans == nil {
		service.cachedScans = service.scanRepos()
	}
	if scope.Cmux || !service.haveWorkspaces {
		service.cachedWorkspaces, service.cmuxErr = service.Cmux.Workspaces()
		service.haveWorkspaces = true
	}
	scans, workspaces, cmuxErr := service.cachedScans, service.cachedWorkspaces, service.cmuxErr
	agents := cmux.AgentSessions()
	sessions := service.buildSessions(scans, agents)
	tasks := service.buildTasks(scans, sessions, workspaces)
	service.allSessions = sessions

	snapshot := Snapshot{
		GeneratedAt: time.Now(),
		CmuxRunning: cmuxErr == nil,
		Tasks:       tasks,
	}
	for _, scan := range scans {
		snapshot.Repos = append(snapshot.Repos, scan.repo)
	}
	cutoff := time.Now().AddDate(0, 0, -snapshotSessionDays)
	for _, session := range sessions {
		if session.State == StateRunning || session.State == StateWaiting || session.Last.After(cutoff) {
			snapshot.Sessions = append(snapshot.Sessions, session)
		}
		if len(snapshot.Sessions) >= snapshotSessionLimit {
			break
		}
	}
	for _, session := range sessions {
		switch session.State {
		case StateRunning:
			snapshot.Counts.Running++
		case StateWaiting:
			snapshot.Counts.Waiting++
		}
	}
	for _, task := range tasks {
		if task.Hidden || task.ParentID != "" {
			continue
		}
		snapshot.Counts.Tasks++
		if task.Workspace != nil {
			snapshot.Counts.Open++
		}
	}
	return snapshot, nil
}

func (service *Service) scanRepos() []*repoScan {
	paths := gitscan.FindRepos(service.roots(), maxRepoDepth)
	scans := make([]*repoScan, len(paths))
	var group sync.WaitGroup
	for index, path := range paths {
		group.Add(1)
		go func() {
			defer group.Done()
			scans[index] = service.scanRepo(path)
		}()
	}
	group.Wait()
	sort.Slice(scans, func(left, right int) bool { return scans[left].repo.Name < scans[right].repo.Name })
	return scans
}

func (service *Service) scanRepo(path string) *repoScan {
	settings := service.repoSettings(path)
	scan := &repoScan{
		repo: Repo{
			Path:       path,
			Name:       service.repoName(path),
			Label:      RepoLabel(path),
			BaseBranch: settings.BaseBranch,
			ServerCmd:  settings.ServerCmd,
		},
		dirty:    map[string]int{},
		localSet: map[string]bool{},
	}
	worktrees, err := service.Git.Worktrees(path)
	if err != nil {
		scan.repo.Error = err.Error()
		return scan
	}
	scan.worktrees = worktrees
	scan.repo.Worktrees = worktrees
	scan.branches, _ = service.Git.Branches(path)
	for _, branch := range scan.branches {
		scan.localSet[branch.Name] = true
	}
	scan.merged = service.Git.Merged(path, settings.BaseBranch)

	var mutex sync.Mutex
	var group sync.WaitGroup
	for _, worktree := range worktrees {
		if worktree.Missing {
			continue
		}
		group.Add(1)
		go func() {
			defer group.Done()
			out, err := service.Git.Run(worktree.Path, "status", "--porcelain")
			count := 0
			if err == nil && out != "" {
				count = len(strings.Split(out, "\n"))
			}
			mutex.Lock()
			scan.dirty[worktree.Path] = count
			mutex.Unlock()
		}()
	}
	group.Wait()
	return scan
}

// matchRepo finds the repo a session cwd belongs to, including deleted sibling worktrees.
func matchRepo(scans []*repoScan, cwd string) *repoScan {
	for _, scan := range scans {
		for _, worktree := range scan.worktrees {
			if cwd == worktree.Path || strings.HasPrefix(cwd, worktree.Path+"/") {
				return scan
			}
		}
	}
	for _, scan := range scans {
		base := filepath.Base(scan.repo.Path)
		parent := filepath.Dir(scan.repo.Path)
		if filepath.Dir(cwd) == parent && strings.HasPrefix(filepath.Base(cwd), base+"-") {
			return scan
		}
	}
	return nil
}

func (service *Service) buildSessions(scans []*repoScan, agents map[string]cmux.AgentSession) []Session {
	var sessions []Session
	resolved := map[string]string{}
	for _, raw := range service.Index.List() {
		cwd, ok := resolved[raw.Cwd]
		if !ok {
			cwd = canonical(raw.Cwd)
			resolved[raw.Cwd] = cwd
		}
		raw.Cwd = cwd
		if !service.inRoots(raw.Cwd) {
			continue
		}
		sessions = append(sessions, service.toSession(raw, scans, agents))
	}
	return sessions
}

func (service *Service) toSession(raw claudeidx.Session, scans []*repoScan, agents map[string]cmux.AgentSession) Session {
	session := Session{
		ID:          raw.ID,
		Title:       raw.Title(),
		Alias:       service.State.Aliases[raw.ID],
		FirstPrompt: raw.FirstPrompt,
		Cwd:         raw.Cwd,
		Branch:      raw.LastBranch,
		Branches:    raw.Branches,
		Start:       raw.Start,
		Last:        raw.Last,
		Prompts:     raw.Prompts,
		Size:        raw.Size,
		State:       StateIdle,
		CwdExists:   exists(raw.Cwd),
	}
	scan := matchRepo(scans, raw.Cwd)
	if scan != nil {
		session.Repo = scan.repo.Path
	}
	if agent, ok := agents[raw.ID]; ok && agent.Alive && agents != nil {
		session.Workspace = agent.WorkspaceID
		session.Surface = agent.SurfaceID
		session.State = StateWaiting
		if agent.Lifecycle == "running" {
			session.State = StateRunning
		}
		return session
	}
	branchExists := len(raw.Branches) == 0
	if scan != nil {
		for _, branch := range raw.Branches {
			if scan.localSet[branch] {
				branchExists = true
			}
		}
	}
	if !session.CwdExists || !branchExists {
		session.State = StateOrphan
	}
	return session
}

func isBase(name, base string) bool {
	return name == base || slices.Contains(conventionalBases, name)
}

// TaskID is stable across worktree moves: <repo>#<branch>.
func TaskID(repo, branch string) string { return config.Collapse(repo) + "#" + branch }

func (service *Service) buildTasks(scans []*repoScan, sessions []Session, workspaces []cmux.Workspace) []Task {
	recentCutoff := time.Now().AddDate(0, 0, -service.Config.RecentDays)
	var tasks []Task
	byID := map[string]int{}
	for _, scan := range scans {
		branchInfo := map[string]gitscan.Branch{}
		for _, branch := range scan.branches {
			branchInfo[branch.Name] = branch
		}
		checkedOut := map[string]bool{}
		add := func(task Task) {
			byID[task.ID] = len(tasks)
			tasks = append(tasks, task)
		}
		for _, worktree := range scan.worktrees {
			task := service.newTask(scan, worktree.Branch, branchInfo[worktree.Branch])
			task.Path = worktree.Path
			task.MainWorktree = worktree.Main
			task.Missing = worktree.Missing
			task.Dirty = scan.dirty[worktree.Path]
			if worktree.Detached || worktree.Branch == "" {
				task.Detached = true
				task.Branch = "(detached)"
				task.ID = config.Collapse(scan.repo.Path) + "#@" + config.Collapse(worktree.Path)
			}
			checkedOut[worktree.Branch] = true
			add(task)
		}
		for _, branch := range scan.branches {
			if checkedOut[branch.Name] {
				continue
			}
			task := service.newTask(scan, branch.Name, branch)
			if task.IsBase && !task.Pinned {
				continue
			}
			byID[task.ID] = -1 // candidate; kept if recent, pinned, or has sessions
			if branch.CommitDate.After(recentCutoff) || task.Pinned {
				add(task)
			}
		}
		// Branch tasks that only qualify because of sessions.
		for _, session := range sessions {
			if session.Repo != scan.repo.Path {
				continue
			}
			for _, branch := range session.Branches {
				id := TaskID(scan.repo.Path, branch)
				if position, ok := byID[id]; ok && position == -1 {
					add(service.newTask(scan, branch, branchInfo[branch]))
				}
			}
		}
	}

	// Attach sessions: primary = last branch; also any non-base branch the session touched.
	for index := range sessions {
		session := &sessions[index]
		if session.Repo == "" {
			continue
		}
		attached := map[int]bool{}
		for _, branch := range append([]string{session.Branch}, session.Branches...) {
			position, ok := byID[TaskID(session.Repo, branch)]
			if !ok || position < 0 || attached[position] {
				continue
			}
			if branch != session.Branch && tasks[position].IsBase {
				continue
			}
			copy := *session
			copy.Primary = session.TaskID == ""
			if copy.Primary {
				session.TaskID = tasks[position].ID
				copy.TaskID = session.TaskID
			}
			attached[position] = true
			tasks[position].Sessions = append(tasks[position].Sessions, copy)
		}
	}

	for index := range tasks {
		task := &tasks[index]
		task.Workspace = findWorkspace(task, workspaces)
		task.LastActivity = task.CommitDate
		for _, session := range task.Sessions {
			if !session.Primary {
				continue
			}
			if session.Last.After(task.LastActivity) {
				task.LastActivity = session.Last
			}
			switch session.State {
			case StateRunning:
				task.Running++
			case StateWaiting:
				task.Waiting++
			}
		}
		if task.Sessions == nil {
			task.Sessions = []Session{}
		}
	}
	foldEnvBranches(tasks)
	for index := range tasks {
		sessions := tasks[index].Sessions
		sort.SliceStable(sessions, func(left, right int) bool { return sessions[left].Last.After(sessions[right].Last) })
	}
	sort.SliceStable(tasks, func(left, right int) bool {
		if tasks[left].Pinned != tasks[right].Pinned {
			return tasks[left].Pinned
		}
		return tasks[left].LastActivity.After(tasks[right].LastActivity)
	})
	return tasks
}

func (service *Service) newTask(scan *repoScan, branch string, info gitscan.Branch) Task {
	id := TaskID(scan.repo.Path, branch)
	return Task{
		ID:         id,
		Repo:       scan.repo.Path,
		RepoName:   scan.repo.Name,
		RepoLabel:  scan.repo.Label,
		Branch:     branch,
		Ticket:     gitops.Ticket(branch),
		IsBase:     isBase(branch, scan.repo.BaseBranch),
		CommitDate: info.CommitDate,
		Subject:    info.Subject,
		Upstream:   info.Upstream,
		Gone:       info.Gone,
		Merged:     scan.merged[branch],
		Ahead:      info.Ahead,
		Behind:     info.Behind,
		Pinned:     service.State.IsPinned(id),
		Hidden:     service.State.IsHidden(id),
		Note:       service.State.Notes[id],
	}
}

// findWorkspace matches a cmux workspace to a task: by a live session's workspace, else by cwd.
func findWorkspace(task *Task, workspaces []cmux.Workspace) *Workspace {
	convert := func(workspace cmux.Workspace) *Workspace {
		return &Workspace{ID: workspace.ID, Ref: workspace.Ref, Title: workspace.Title, Ports: workspace.Ports, Selected: workspace.Selected}
	}
	for _, session := range task.Sessions {
		if session.Workspace == "" || !session.Primary {
			continue
		}
		for _, workspace := range workspaces {
			if strings.EqualFold(workspace.ID, session.Workspace) {
				return convert(workspace)
			}
		}
	}
	if task.Path == "" {
		return nil
	}
	for _, workspace := range workspaces {
		if canonical(workspace.Cwd) == task.Path {
			return convert(workspace)
		}
	}
	return nil
}

// envSuffixes are the per-environment cherry-pick branches (<feature>-dev, <ticket>-stg).
var envSuffixes = []string{"-dev", "-stg", "-staging", "-development", "-prod"}

func envBase(branch string) (string, bool) {
	for _, suffix := range envSuffixes {
		if strings.HasSuffix(branch, suffix) {
			return strings.TrimSuffix(branch, suffix), true
		}
	}
	return "", false
}

// foldEnvBranches hides -dev/-stg branches that have no folder of their own under their feature
// task (matched by name prefix, else by ticket), merging their sessions into it.
func foldEnvBranches(tasks []Task) {
	for index := range tasks {
		env := &tasks[index]
		base, ok := envBase(env.Branch)
		if !ok || env.Path != "" || env.Pinned {
			continue
		}
		parent := -1
		for candidate := range tasks {
			other := &tasks[candidate]
			if candidate == index || other.Repo != env.Repo || other.IsBase {
				continue
			}
			if _, otherIsEnv := envBase(other.Branch); otherIsEnv {
				continue
			}
			if other.Branch == base || strings.HasPrefix(other.Branch, base+"-") {
				parent = candidate
				break
			}
			if parent == -1 && env.Ticket != "" && other.Ticket == env.Ticket {
				parent = candidate
			}
		}
		if parent == -1 {
			continue
		}
		feature := &tasks[parent]
		env.ParentID = feature.ID
		feature.Running += env.Running
		feature.Waiting += env.Waiting
		if env.LastActivity.After(feature.LastActivity) {
			feature.LastActivity = env.LastActivity
		}
		feature.EnvBranches = append(feature.EnvBranches, env.Branch)
		known := map[string]bool{}
		for _, session := range feature.Sessions {
			known[session.ID] = true
		}
		for _, session := range env.Sessions {
			if !known[session.ID] {
				session.Primary = false
				feature.Sessions = append(feature.Sessions, session)
			}
		}
	}
}
