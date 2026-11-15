package prs

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseRemote(t *testing.T) {
	cases := map[string]Remote{
		"git@github.com:acme/web.git":                {"github.com", "acme", "web"},
		"https://github.com/acme/web":                {"github.com", "acme", "web"},
		"ssh://git@bitbucket.org/team/portal.git":    {"bitbucket.org", "team", "portal"},
		"https://someone@bitbucket.org/team/portal/": {"bitbucket.org", "team", "portal"},
	}
	for input, want := range cases {
		if got, ok := ParseRemote(input + "\n"); !ok || got != want {
			t.Errorf("%s: got %+v %v", input, got, ok)
		}
	}
}

func TestParseGitHubStatesAndChecks(t *testing.T) {
	data := `[
	 {"number":1,"state":"OPEN","isDraft":false,"headRefName":"a","reviewDecision":"APPROVED","updatedAt":"2026-11-01T00:00:00Z",
	  "statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"state":"FAILURE"}]},
	 {"number":2,"state":"OPEN","isDraft":true,"headRefName":"b","updatedAt":"2026-11-01T00:00:00Z",
	  "statusCheckRollup":[{"status":"IN_PROGRESS"}]},
	 {"number":3,"state":"MERGED","headRefName":"a","updatedAt":"2026-11-05T00:00:00Z"}
	]`
	list, err := ParseGitHub([]byte(data))
	if err != nil {
		t.Fatal(err)
	}
	best := pick(list)
	if a := best["a"]; a.Number != 1 || a.Checks != "failing" || a.Review != "approved" || a.State != "open" {
		t.Errorf("a = %+v (an open PR beats a newer merged one)", a)
	}
	if b := best["b"]; b.State != "draft" || b.Checks != "pending" {
		t.Errorf("b = %+v", b)
	}
}

func TestBitbucketFetchUsesTokenAndStatuses(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if user, token, _ := request.BasicAuth(); user != "me@example.com" || token != "secret" {
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case strings.HasSuffix(request.URL.Path, "/pullrequests/7/statuses"):
			writer.Write([]byte(`{"values":[{"state":"SUCCESSFUL"},{"state":"INPROGRESS"}]}`))
		case strings.HasSuffix(request.URL.Path, "/repositories/team/portal/pullrequests"):
			writer.Write([]byte(`{"values":[
			 {"id":7,"title":"Feature","state":"OPEN","source":{"branch":{"name":"feat"}},"links":{"html":{"href":"https://bb/7"}},
			  "updated_on":"2026-11-01T00:00:00Z","participants":[{"approved":true,"state":"approved"}]},
			 {"id":5,"title":"Old","state":"MERGED","source":{"branch":{"name":"old"}},"updated_on":"2026-10-01T00:00:00Z"}]}`))
		default:
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	fetcher := Fetcher{BitbucketUser: "me@example.com", Token: func() string { return "secret" }, BitbucketAPI: server.URL}
	got, err := fetcher.Fetch("", Remote{"bitbucket.org", "team", "portal"})
	if err != nil {
		t.Fatal(err)
	}
	if pr := got["feat"]; pr.Number != 7 || pr.Checks != "pending" || pr.Review != "approved" || pr.URL != "https://bb/7" {
		t.Errorf("feat = %+v", pr)
	}
	if got["old"].State != "merged" {
		t.Errorf("old = %+v", got["old"])
	}
	fetcher.Token = func() string { return "" }
	if _, err := fetcher.Fetch("", Remote{"bitbucket.org", "team", "portal"}); err != ErrNoToken {
		t.Errorf("err = %v, want ErrNoToken", err)
	}
	fetcher.Token = func() string { return "wrong" }
	if _, err := fetcher.Fetch("", Remote{"bitbucket.org", "team", "portal"}); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Errorf("err = %v", err)
	}
}
