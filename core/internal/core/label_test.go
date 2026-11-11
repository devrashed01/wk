package core

import "testing"

func TestRepoLabelStripsConfiguredPrefixes(t *testing.T) {
	labelStripPrefixes = []string{"acme-"}
	defer func() { labelStripPrefixes = nil }()
	cases := map[string]string{"/x/acme-widget": "WIDGET", "/x/admin": "ADMIN", "/x/acme-": "ACME-"}
	for path, want := range cases {
		if got := RepoLabel(path); got != want {
			t.Errorf("RepoLabel(%q) = %q, want %q", path, got, want)
		}
	}
}
