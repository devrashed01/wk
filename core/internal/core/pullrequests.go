package core

import (
	"os"
	"os/exec"
	"sort"
	"strings"

	"wk/internal/config"
	"wk/internal/gitops"
	"wk/internal/gitscan"
	"wk/internal/jira"
	"wk/internal/prs"
)

// attachPRs puts each branch's pull request on its task from the cache, and starts a background
// refresh of repos whose data is stale. Results land on a later snapshot.
func (service *Service) attachPRs(snapshot *Snapshot) {
	if service.PRs == nil {
		return
	}
	repos := make([]string, 0, len(snapshot.Repos))
	for index := range snapshot.Repos {
		repo := &snapshot.Repos[index]
		repos = append(repos, repo.Path)
		repo.PRError = service.PRs.Get(repo.Path).Error
	}
	for index := range snapshot.Tasks {
		task := &snapshot.Tasks[index]
		if task.IsBase || task.Detached {
			continue
		}
		branches := service.PRs.Get(task.Repo).Branches
		if pr, ok := branches[task.Branch]; ok {
			task.PR = &pr
		}
		if _, isEnv := envBase(task.Branch); !isEnv {
			task.EnvPRs = envPRs(*task, branches)
		}
	}
	service.remoteRepos = repos
	service.PRs.Refresh(repos, service.prFetcher(), service.Git.Bin, false)
}

func (service *Service) prFetcher() prs.Fetcher {
	return prs.Fetcher{
		GhBin:         gitscan.FindBin("gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"),
		BitbucketUser: service.Config.BitbucketUser,
		Token:         prs.KeychainToken(service.Config.BitbucketUser),
	}
}

// RefreshPRs fetches pull requests for every repo now (after the token changes, or on demand).
func (service *Service) RefreshPRs() error {
	snapshot, err := service.Snapshot()
	if err != nil || service.PRs == nil {
		return err
	}
	repos := make([]string, 0, len(snapshot.Repos))
	for _, repo := range snapshot.Repos {
		repos = append(repos, repo.Path)
	}
	service.PRs.Refresh(repos, service.prFetcher(), service.Git.Bin, true)
	return nil
}

// RefreshRemote refetches pull requests and Jira tickets for what the last snapshot showed:
// only stale ones, or all of them when force. Results land in the caches (and the app's next
// snapshot) when they arrive.
func (service *Service) RefreshRemote(force bool) error {
	if service.remoteRepos == nil {
		if _, err := service.Snapshot(); err != nil {
			return err
		}
	}
	if service.PRs != nil {
		service.PRs.Refresh(service.remoteRepos, service.prFetcher(), service.Git.Bin, force)
	}
	if service.Jira != nil && service.Config.JiraSite != "" {
		service.Jira.Refresh(service.remoteKeys, service.jiraClient(), force)
	}
	return nil
}

// Fetching says what is being fetched from the hosts right now.
type Fetching struct {
	PRs  bool `json:"prs"`
	Jira bool `json:"jira"`
}

func (service *Service) Fetching() Fetching {
	var state Fetching
	if service.PRs != nil {
		state.PRs = service.PRs.Busy()
	}
	if service.Jira != nil {
		state.Jira = service.Jira.Busy()
	}
	return state
}

// envPRs finds the PRs of a feature's environment branches by name, so they show even when the
// branch itself was never fetched or is already deleted: <branch>-stg, <branch-prefix>-dev, or
// <ticket>-dev for the same ticket.
func envPRs(task Task, branches map[string]prs.PR) []EnvPR {
	var list []EnvPR
	for branch, pr := range branches {
		base, ok := envBase(branch)
		if !ok {
			continue
		}
		matches := task.Branch == base || strings.HasPrefix(task.Branch, base+"-") ||
			(task.Ticket != "" && gitops.Ticket(base) == task.Ticket)
		if matches {
			list = append(list, EnvPR{Env: strings.TrimPrefix(branch[len(base):], "-"), Branch: branch, PR: pr})
		}
	}
	sort.Slice(list, func(left, right int) bool {
		if rank(list[left].Env) != rank(list[right].Env) {
			return rank(list[left].Env) < rank(list[right].Env)
		}
		return list[left].Branch < list[right].Branch
	})
	return list
}

func rank(env string) int {
	for index, suffix := range envSuffixes {
		if "-"+env == suffix {
			return index
		}
	}
	return len(envSuffixes)
}

// attachIssues puts each ticket's Jira issue on its task from the cache and refreshes stale
// ones in the background. Without a Jira site nothing is fetched.
func (service *Service) attachIssues(snapshot *Snapshot) {
	if service.Jira == nil || service.Config.JiraSite == "" {
		return
	}
	seen := map[string]bool{}
	var keys []string
	for index := range snapshot.Tasks {
		task := &snapshot.Tasks[index]
		if task.Ticket == "" {
			continue
		}
		if issue, ok := service.Jira.Get(task.Ticket); ok {
			task.Issue = &issue
		}
		if !seen[task.Ticket] {
			seen[task.Ticket] = true
			keys = append(keys, task.Ticket)
		}
	}
	snapshot.JiraError = service.Jira.Error()
	service.remoteKeys = keys
	service.Jira.Refresh(keys, service.jiraClient(), false)
}

func (service *Service) jiraClient() *jira.Client {
	user := service.Config.JiraUser
	if user == "" {
		user = service.Config.BitbucketUser
	}
	return &jira.Client{Site: service.Config.JiraSite, User: user, Token: jira.KeychainToken(user)}
}

// RefreshJira fetches every ticket again now (after the Jira settings change).
func (service *Service) RefreshJira() error {
	snapshot, err := service.Snapshot()
	if err != nil || service.Jira == nil || service.Config.JiraSite == "" {
		return err
	}
	var keys []string
	seen := map[string]bool{}
	for _, task := range snapshot.Tasks {
		if task.Ticket != "" && !seen[task.Ticket] {
			seen[task.Ticket] = true
			keys = append(keys, task.Ticket)
		}
	}
	service.Jira.Refresh(keys, service.jiraClient(), true)
	return nil
}

// DetectJiraSite finds the Jira site from names around the repos (email domain, folders, remote
// owners), saves it in the config and returns it.
func (service *Service) DetectJiraSite() (string, error) {
	snapshot, err := service.Snapshot()
	if err != nil {
		return "", err
	}
	client := service.jiraClient()
	var keys []string
	seen := map[string]bool{}
	for _, task := range snapshot.Tasks {
		if task.Ticket != "" && !seen[task.Ticket] {
			seen[task.Ticket] = true
			keys = append(keys, task.Ticket)
		}
	}
	var candidates []string
	add := func(text string) {
		for _, part := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return r == '/' || r == '.' || r == '_' || r == ' ' }) {
			candidates = append(candidates, part)
			if first, _, ok := strings.Cut(part, "-"); ok {
				candidates = append(candidates, first)
			}
		}
	}
	if _, domain, ok := strings.Cut(client.User, "@"); ok {
		label, _, _ := strings.Cut(domain, ".")
		add(label)
	}
	for _, root := range service.roots() {
		add(strings.TrimPrefix(root, os.Getenv("HOME")))
	}
	for _, repo := range snapshot.Repos {
		add(repo.Name)
		if out, err := exec.Command(service.Git.Bin, "-C", repo.Path, "remote", "get-url", "origin").Output(); err == nil {
			if remote, ok := prs.ParseRemote(string(out)); ok {
				add(remote.Owner)
			}
		}
	}
	site, err := jira.DetectSite(candidates, keys, client.User, client.Token)
	if err != nil {
		return "", err
	}
	service.Config.JiraSite = site
	if err := config.Save(service.Config); err != nil {
		return "", err
	}
	_ = service.RefreshJira()
	return site, nil
}
