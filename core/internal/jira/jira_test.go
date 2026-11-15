package jira

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFetchReadsIssueAndHandlesMissing(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if user, token, _ := request.BasicAuth(); user != "me@example.com" || token != "secret" {
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case strings.HasSuffix(request.URL.Path, "/issue/ABC-1"):
			writer.Write([]byte(`{"key":"ABC-1","fields":{"summary":"Files tab","status":{"name":"Code Review","statusCategory":{"key":"indeterminate"}},"assignee":{"displayName":"Sam"}}}`))
		default:
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	client := &Client{Site: server.URL, User: "me@example.com", Token: func() string { return "secret" }}
	issue, err := client.Fetch("ABC-1")
	if err != nil || issue == nil {
		t.Fatalf("issue=%v err=%v", issue, err)
	}
	if issue.Summary != "Files tab" || issue.Status != "Code Review" || issue.Category != "indeterminate" || issue.Assignee != "Sam" || issue.URL != server.URL+"/browse/ABC-1" {
		t.Errorf("issue = %+v", issue)
	}
	if missing, err := client.Fetch("ABC-404"); missing != nil || err != nil {
		t.Errorf("missing = %v, %v", missing, err)
	}
	client.Token = func() string { return "" }
	if _, err := client.Fetch("ABC-1"); err != ErrNoToken {
		t.Errorf("err = %v", err)
	}
}

func TestCacheFetchesInBackgroundAndSaves(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Write([]byte(`{"key":"ABC-2","fields":{"summary":"S","status":{"name":"Done","statusCategory":{"key":"done"}}}}`))
	}))
	defer server.Close()
	path := t.TempDir() + "/jira.json"
	cache := NewCache(path)
	cache.Refresh([]string{"ABC-2"}, &Client{Site: server.URL, User: "u", Token: func() string { return "t" }}, false)
	for range 100 {
		if _, ok := cache.Get("ABC-2"); ok {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if issue, ok := NewCache(path).Get("ABC-2"); !ok || issue.Status != "Done" {
		t.Fatalf("not saved to disk: %+v %v", issue, ok)
	}
}

func TestScopedTokenFallsBackToGatewayOnNotFound(t *testing.T) {
	var gateway *httptest.Server
	site := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/_edge/tenant_info" {
			writer.Write([]byte(`{"cloudId":"abc"}`))
			return
		}
		writer.WriteHeader(http.StatusNotFound) // what Jira says to a scoped token
	}))
	defer site.Close()
	gateway = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Write([]byte(`{"key":"ABC-3","fields":{"summary":"Via gateway","status":{"name":"To Do"}}}`))
	}))
	defer gateway.Close()
	client := &Client{Site: site.URL, User: "u", Token: func() string { return "t" }, gatewayBase: gateway.URL + "/ex/jira/"}
	issue, err := client.Fetch("ABC-3")
	if err != nil || issue == nil || issue.Summary != "Via gateway" {
		t.Fatalf("issue=%+v err=%v", issue, err)
	}
}
