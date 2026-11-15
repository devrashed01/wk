// Package prs finds the pull request for each branch: GitHub through the gh CLI, Bitbucket
// Cloud through its REST API with a token from the macOS Keychain.
package prs

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// PR is one pull request, as shown next to its branch.
type PR struct {
	Number  int       `json:"number"`
	Title   string    `json:"title"`
	State   string    `json:"state"` // open, draft, merged, closed
	URL     string    `json:"url"`
	Checks  string    `json:"checks,omitempty"` // passing, failing, pending
	Review  string    `json:"review,omitempty"` // approved, changes_requested
	Updated time.Time `json:"updated"`
}

func (pr PR) Live() bool { return pr.State == "open" || pr.State == "draft" }

// Remote is a hosted repository parsed from a git remote URL.
type Remote struct{ Host, Owner, Name string }

var remotePattern = regexp.MustCompile(`^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)(?::\d+)?[:/]([^/]+)/([^/]+?)(?:\.git)?/?$`)

// ParseRemote understands git@host:owner/name.git, ssh://git@host/owner/name and https://[user@]host/owner/name.
func ParseRemote(remote string) (Remote, bool) {
	match := remotePattern.FindStringSubmatch(strings.TrimSpace(remote))
	if match == nil {
		return Remote{}, false
	}
	return Remote{Host: strings.ToLower(match[1]), Owner: match[2], Name: match[3]}, true
}

// ErrNoToken means a Bitbucket repo was found but no token is set up.
var ErrNoToken = errors.New("add a Bitbucket API token in wk Settings → Pull requests")

// Fetcher talks to the hosts.
type Fetcher struct {
	GhBin         string
	BitbucketUser string
	Token         func() string // Bitbucket API token; "" when missing
	HTTP          *http.Client
	BitbucketAPI  string // overridden in tests
}

// Supported reports whether the remote's host is one wk can ask.
func Supported(remote Remote) bool {
	return remote.Host == "github.com" || remote.Host == "bitbucket.org"
}

// Fetch returns the most relevant PR per source branch: a live one first, then the newest.
func (fetcher Fetcher) Fetch(repo string, remote Remote) (map[string]PR, error) {
	var list []branchPR
	var err error
	switch remote.Host {
	case "github.com":
		list, err = fetcher.github(repo, remote)
	case "bitbucket.org":
		list, err = fetcher.bitbucket(remote)
	default:
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return pick(list), nil
}

type branchPR struct {
	branch string
	pr     PR
}

func pick(list []branchPR) map[string]PR {
	best := map[string]PR{}
	for _, item := range list {
		current, ok := best[item.branch]
		if !ok || (item.pr.Live() && !current.Live()) || (item.pr.Live() == current.Live() && item.pr.Updated.After(current.Updated)) {
			best[item.branch] = item.pr
		}
	}
	return best
}

// GitHub

type ghPR struct {
	Number         int       `json:"number"`
	Title          string    `json:"title"`
	State          string    `json:"state"`
	IsDraft        bool      `json:"isDraft"`
	HeadRefName    string    `json:"headRefName"`
	URL            string    `json:"url"`
	ReviewDecision string    `json:"reviewDecision"`
	UpdatedAt      time.Time `json:"updatedAt"`
	Checks         []ghCheck `json:"statusCheckRollup"`
}

type ghCheck struct {
	Status     string `json:"status"`     // CheckRun: QUEUED, IN_PROGRESS, COMPLETED
	Conclusion string `json:"conclusion"` // CheckRun: SUCCESS, FAILURE, ...
	State      string `json:"state"`      // StatusContext: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED
}

func (fetcher Fetcher) github(repo string, remote Remote) ([]branchPR, error) {
	cmd := exec.Command(fetcher.GhBin, "pr", "list", "--repo", remote.Owner+"/"+remote.Name, "--state", "all", "--limit", "100",
		"--json", "number,title,state,isDraft,headRefName,url,reviewDecision,updatedAt,statusCheckRollup")
	cmd.Dir = repo
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return nil, errors.New("install the GitHub CLI (brew install gh) and run gh auth login to see pull requests")
		}
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf("gh: %s", firstLine(message))
	}
	return ParseGitHub(stdout.Bytes())
}

func ParseGitHub(data []byte) ([]branchPR, error) {
	var raw []ghPR
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	list := make([]branchPR, 0, len(raw))
	for _, item := range raw {
		pr := PR{Number: item.Number, Title: item.Title, URL: item.URL, Updated: item.UpdatedAt, Checks: githubChecks(item.Checks)}
		switch {
		case item.State == "MERGED":
			pr.State = "merged"
		case item.State == "CLOSED":
			pr.State = "closed"
		case item.IsDraft:
			pr.State = "draft"
		default:
			pr.State = "open"
		}
		switch item.ReviewDecision {
		case "APPROVED":
			pr.Review = "approved"
		case "CHANGES_REQUESTED":
			pr.Review = "changes_requested"
		}
		list = append(list, branchPR{branch: item.HeadRefName, pr: pr})
	}
	return list, nil
}

func githubChecks(checks []ghCheck) string {
	if len(checks) == 0 {
		return ""
	}
	pending := false
	for _, check := range checks {
		switch {
		case check.Conclusion == "FAILURE" || check.Conclusion == "TIMED_OUT" || check.Conclusion == "CANCELLED" ||
			check.Conclusion == "ACTION_REQUIRED" || check.Conclusion == "STARTUP_FAILURE" ||
			check.State == "FAILURE" || check.State == "ERROR":
			return "failing"
		case check.State == "PENDING" || check.State == "EXPECTED" || (check.Status != "" && check.Status != "COMPLETED"):
			pending = true
		}
	}
	if pending {
		return "pending"
	}
	return "passing"
}

// Bitbucket Cloud

type bbPage struct {
	Values []struct {
		ID     int    `json:"id"`
		Title  string `json:"title"`
		State  string `json:"state"` // OPEN, MERGED, DECLINED, SUPERSEDED
		Draft  bool   `json:"draft"`
		Source struct {
			Branch struct {
				Name string `json:"name"`
			} `json:"branch"`
		} `json:"source"`
		Links struct {
			HTML struct {
				Href string `json:"href"`
			} `json:"html"`
		} `json:"links"`
		UpdatedOn    time.Time `json:"updated_on"`
		Participants []struct {
			Approved bool   `json:"approved"`
			State    string `json:"state"` // approved, changes_requested, null
		} `json:"participants"`
	} `json:"values"`
}

type bbStatuses struct {
	Values []struct {
		State string `json:"state"` // SUCCESSFUL, FAILED, INPROGRESS, STOPPED
	} `json:"values"`
}

func (fetcher Fetcher) bitbucket(remote Remote) ([]branchPR, error) {
	token := ""
	if fetcher.Token != nil {
		token = fetcher.Token()
	}
	if fetcher.BitbucketUser == "" || token == "" {
		return nil, ErrNoToken
	}
	base := fetcher.BitbucketAPI
	if base == "" {
		base = "https://api.bitbucket.org/2.0"
	}
	repoURL := base + "/repositories/" + url.PathEscape(remote.Owner) + "/" + url.PathEscape(remote.Name)
	query := url.Values{
		"state":   {"OPEN", "MERGED", "DECLINED", "SUPERSEDED"},
		"pagelen": {"50"},
		"sort":    {"-updated_on"},
		"fields":  {"values.id,values.title,values.state,values.draft,values.source.branch.name,values.links.html.href,values.updated_on,values.participants.approved,values.participants.state"},
	}
	var page bbPage
	if err := fetcher.getJSON(repoURL+"/pullrequests?"+query.Encode(), token, &page); err != nil {
		return nil, err
	}
	list, open := ParseBitbucket(page)
	// Build status is one call per PR: only ask for the few open ones.
	for index, position := range open {
		if index >= 10 {
			break
		}
		var statuses bbStatuses
		pr := &list[position].pr
		if fetcher.getJSON(fmt.Sprintf("%s/pullrequests/%d/statuses?pagelen=50", repoURL, pr.Number), token, &statuses) == nil {
			pr.Checks = bitbucketChecks(statuses)
		}
	}
	return list, nil
}

// ParseBitbucket converts a page of PRs; open lists the positions of live PRs.
func ParseBitbucket(page bbPage) (list []branchPR, open []int) {
	for _, item := range page.Values {
		pr := PR{Number: item.ID, Title: item.Title, URL: item.Links.HTML.Href, Updated: item.UpdatedOn}
		switch item.State {
		case "MERGED":
			pr.State = "merged"
		case "DECLINED", "SUPERSEDED":
			pr.State = "closed"
		default:
			pr.State = "open"
			if item.Draft {
				pr.State = "draft"
			}
		}
		for _, participant := range item.Participants {
			if participant.State == "changes_requested" {
				pr.Review = "changes_requested"
				break
			}
			if participant.Approved || participant.State == "approved" {
				pr.Review = "approved"
			}
		}
		if pr.Live() {
			open = append(open, len(list))
		}
		list = append(list, branchPR{branch: item.Source.Branch.Name, pr: pr})
	}
	return list, open
}

func bitbucketChecks(statuses bbStatuses) string {
	if len(statuses.Values) == 0 {
		return ""
	}
	pending := false
	for _, status := range statuses.Values {
		switch status.State {
		case "FAILED", "STOPPED":
			return "failing"
		case "INPROGRESS":
			pending = true
		}
	}
	if pending {
		return "pending"
	}
	return "passing"
}

func (fetcher Fetcher) getJSON(address, token string, target any) error {
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(fetcher.BitbucketUser+":"+token)))
	client := fetcher.HTTP
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("bitbucket: %w", err)
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden:
		return errors.New("bitbucket refused the token (check the email and token in wk Settings → Pull requests)")
	case response.StatusCode == http.StatusNotFound:
		return errors.New("bitbucket: repository not found or the token can't read it")
	case response.StatusCode >= 300:
		return fmt.Errorf("bitbucket: HTTP %d", response.StatusCode)
	}
	return json.NewDecoder(response.Body).Decode(target)
}

// KeychainToken reads the Bitbucket token wk's Settings saved for user.
func KeychainToken(user string) func() string {
	return func() string {
		if user == "" {
			return ""
		}
		out, err := exec.Command("/usr/bin/security", "find-generic-password", "-s", KeychainService, "-a", user, "-w").Output()
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	}
}

// KeychainService is the Keychain item name the app writes and the core reads.
const KeychainService = "wk.bitbucket"

func firstLine(text string) string {
	line, _, _ := strings.Cut(text, "\n")
	return line
}
