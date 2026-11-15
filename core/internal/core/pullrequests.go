package core

import (
	"sort"
	"strings"

	"wk/internal/gitops"
	"wk/internal/gitscan"
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
