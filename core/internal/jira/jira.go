// Package jira reads ticket title, status and assignee from Jira Cloud, for the tickets in
// branch names. The API token lives in the macOS Keychain (service "wk.jira").
package jira

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Issue is the little wk shows about a ticket.
type Issue struct {
	Key      string `json:"key"`
	Summary  string `json:"summary"`
	Status   string `json:"status"`             // In Progress, Code Review...
	Category string `json:"category,omitempty"` // new, indeterminate, done
	Assignee string `json:"assignee,omitempty"`
	URL      string `json:"url"`
}

const KeychainService = "wk.jira"

// ErrNoToken means Jira isn't set up; tickets just show without a title.
var ErrNoToken = errors.New("add your Jira site and API token in wk Settings → Jira")

// Client talks to one Jira Cloud site.
type Client struct {
	Site  string // acme.atlassian.net
	User  string // Atlassian account email
	Token func() string
	HTTP  *http.Client

	// gateway is https://api.atlassian.com/ex/jira/<cloudId>, used when the site itself refuses
	// the token (scoped API tokens only work through the gateway).
	gateway      string
	gatewayMutex sync.Mutex
	gatewayBase  string // tests point this at a fake; default https://api.atlassian.com/ex/jira/
}

func (client *Client) siteURL() string {
	site := strings.TrimSuffix(strings.TrimSpace(client.Site), "/")
	if site != "" && !strings.Contains(site, "://") {
		site = "https://" + site
	}
	return site
}

// Fetch reads one issue; (nil, nil) when it doesn't exist or isn't visible.
func (client *Client) Fetch(key string) (*Issue, error) {
	token := ""
	if client.Token != nil {
		token = client.Token()
	}
	if client.siteURL() == "" || client.User == "" || token == "" {
		return nil, ErrNoToken
	}
	path := "/rest/api/3/issue/" + url.PathEscape(key) + "?fields=summary,status,assignee"
	client.gatewayMutex.Lock()
	gateway := client.gateway
	client.gatewayMutex.Unlock()
	base := client.siteURL()
	if gateway != "" {
		base = gateway
	}
	status, body, err := client.get(base+path, token)
	if err != nil {
		return nil, err
	}
	// Scoped tokens only work through the gateway; the site itself answers 401, 403 or even 404
	// ("does not exist or you do not have permission"). Try the gateway once and keep it if it works.
	if (status == http.StatusUnauthorized || status == http.StatusForbidden || status == http.StatusNotFound) && gateway == "" {
		if found, err := client.findGateway(); err == nil {
			gatewayStatus, gatewayBody, err := client.get(found+path, token)
			if err == nil && gatewayStatus < 300 {
				client.gatewayMutex.Lock()
				client.gateway = found
				client.gatewayMutex.Unlock()
			}
			if err == nil && (gatewayStatus < 300 || status != http.StatusNotFound) {
				status, body = gatewayStatus, gatewayBody
			}
		}
	}
	switch {
	case status == http.StatusNotFound:
		return nil, nil
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return nil, errors.New("jira refused the token (check the site, email and token in wk Settings → Jira)")
	case status >= 300:
		return nil, fmt.Errorf("jira: HTTP %d", status)
	}
	return parseIssue(body, client.siteURL())
}

func parseIssue(body []byte, site string) (*Issue, error) {
	var raw struct {
		Key    string `json:"key"`
		Fields struct {
			Summary string `json:"summary"`
			Status  struct {
				Name     string `json:"name"`
				Category struct {
					Key string `json:"key"`
				} `json:"statusCategory"`
			} `json:"status"`
			Assignee *struct {
				DisplayName string `json:"displayName"`
			} `json:"assignee"`
		} `json:"fields"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}
	issue := &Issue{
		Key: raw.Key, Summary: raw.Fields.Summary, Status: raw.Fields.Status.Name,
		Category: raw.Fields.Status.Category.Key, URL: site + "/browse/" + raw.Key,
	}
	if raw.Fields.Assignee != nil {
		issue.Assignee = raw.Fields.Assignee.DisplayName
	}
	return issue, nil
}

func (client *Client) findGateway() (string, error) {
	response, err := client.httpClient().Get(client.siteURL() + "/_edge/tenant_info")
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	var info struct {
		CloudID string `json:"cloudId"`
	}
	if err := json.NewDecoder(response.Body).Decode(&info); err != nil || info.CloudID == "" {
		return "", errors.New("jira: couldn't find the site's cloud id")
	}
	base := client.gatewayBase
	if base == "" {
		base = "https://api.atlassian.com/ex/jira/"
	}
	return base + info.CloudID, nil
}

func (client *Client) get(address, token string) (int, []byte, error) {
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		return 0, nil, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(client.User+":"+token)))
	response, err := client.httpClient().Do(request)
	if err != nil {
		return 0, nil, fmt.Errorf("jira: %w", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	return response.StatusCode, body, err
}

func (client *Client) httpClient() *http.Client {
	if client.HTTP != nil {
		return client.HTTP
	}
	return &http.Client{Timeout: 15 * time.Second}
}

// KeychainToken reads the token wk's Settings saved for user.
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

// Cache keeps issues on disk (jira.json) and refreshes stale ones in the background; the file
// only changes when an issue did, which is the app's cue to refresh.
type Cache struct {
	Path string
	TTL  time.Duration
	// OnBusy is called (outside the lock) when fetching starts or stops; see Busy.
	OnBusy func()

	mutex    sync.Mutex
	data     cacheFile
	loaded   bool
	fetching bool
}

type cacheFile struct {
	Fetched map[string]time.Time `json:"fetched"`
	Issues  map[string]Issue     `json:"issues"`
	Error   string               `json:"error,omitempty"`
}

func NewCache(path string) *Cache { return &Cache{Path: path, TTL: 10 * time.Minute} }

func (cache *Cache) load() {
	if cache.loaded {
		return
	}
	cache.loaded = true
	if raw, err := os.ReadFile(cache.Path); err == nil {
		_ = json.Unmarshal(raw, &cache.data)
	}
	if cache.data.Fetched == nil {
		cache.data.Fetched = map[string]time.Time{}
	}
	if cache.data.Issues == nil {
		cache.data.Issues = map[string]Issue{}
	}
}

// Get returns the cached issue for key, if any.
func (cache *Cache) Get(key string) (Issue, bool) {
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	cache.load()
	issue, ok := cache.data.Issues[key]
	return issue, ok
}

// Error is why the last fetch failed ("" when it worked).
func (cache *Cache) Error() string {
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	cache.load()
	return cache.data.Error
}

// Refresh fetches stale keys in the background (all of them when force).
func (cache *Cache) Refresh(keys []string, client *Client, force bool) {
	cache.mutex.Lock()
	cache.load()
	if cache.fetching {
		cache.mutex.Unlock()
		return
	}
	var stale []string
	for _, key := range keys {
		if force || time.Since(cache.data.Fetched[key]) >= cache.TTL {
			stale = append(stale, key)
		}
	}
	if len(stale) == 0 {
		cache.mutex.Unlock()
		return
	}
	cache.fetching = true
	cache.mutex.Unlock()
	if cache.OnBusy != nil {
		cache.OnBusy()
	}
	go cache.fetch(stale, client)
}

// Busy reports whether a fetch is running.
func (cache *Cache) Busy() bool {
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	return cache.fetching
}

func (cache *Cache) fetch(keys []string, client *Client) {
	type result struct {
		key   string
		issue *Issue
		err   error
	}
	results := make(chan result, len(keys))
	limit := make(chan struct{}, 6)
	var group sync.WaitGroup
	for _, key := range keys {
		group.Add(1)
		go func() {
			defer group.Done()
			limit <- struct{}{}
			defer func() { <-limit }()
			issue, err := client.Fetch(key)
			results <- result{key, issue, err}
		}()
	}
	group.Wait()
	close(results)

	cache.mutex.Lock()
	defer func() {
		cache.mutex.Unlock()
		if cache.OnBusy != nil {
			cache.OnBusy()
		}
	}()
	cache.fetching = false
	before := cache.data.Error
	beforeIssues := make(map[string]Issue, len(cache.data.Issues))
	for key, issue := range cache.data.Issues {
		beforeIssues[key] = issue
	}
	cache.data.Error = ""
	now := time.Now()
	for item := range results {
		if item.err != nil {
			cache.data.Error = item.err.Error()
			if errors.Is(item.err, ErrNoToken) {
				cache.data.Fetched[item.key] = now // don't retry every snapshot until set up
			}
			continue
		}
		cache.data.Fetched[item.key] = now
		if item.issue == nil {
			delete(cache.data.Issues, item.key)
		} else {
			cache.data.Issues[item.key] = *item.issue
		}
	}
	if before != cache.data.Error || !reflect.DeepEqual(beforeIssues, cache.data.Issues) {
		cache.save()
	}
}

func (cache *Cache) save() {
	raw, err := json.Marshal(cache.data)
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(cache.Path), 0o755)
	temp := cache.Path + ".tmp"
	if os.WriteFile(temp, raw, 0o600) == nil {
		_ = os.Rename(temp, cache.Path)
	}
}

// DetectSite tries each candidate name as <name>.atlassian.net and returns the first site where
// the token can read one of the keys. Unknown names cost one public request each.
func DetectSite(candidates, keys []string, user string, token func() string) (string, error) {
	if len(keys) == 0 {
		return "", errors.New("no branch names a ticket yet, so there is nothing to test the site with")
	}
	if len(keys) > 3 {
		keys = keys[:3]
	}
	tried := map[string]bool{}
	for _, name := range candidates {
		name = strings.ToLower(strings.TrimSpace(name))
		if name == "" || tried[name] || !siteName.MatchString(name) {
			continue
		}
		tried[name] = true
		client := &Client{Site: name + ".atlassian.net", User: user, Token: token, HTTP: &http.Client{Timeout: 8 * time.Second}}
		if _, err := client.findGateway(); err != nil {
			continue // no such site
		}
		for _, key := range keys {
			if issue, err := client.Fetch(key); err == nil && issue != nil {
				return client.Site, nil
			}
		}
	}
	return "", errors.New("couldn't find a site where this token can read your tickets; enter it by hand")
}

var siteName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,40}$`)
