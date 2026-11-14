package main

import "testing"

func TestSelectorMovesFiltersAndPicks(t *testing.T) {
	state := newSelector([]string{"main", "feature/login", "fix/login-crash", "release"})
	state.key("\x1b[B")
	state.key("\x1b[B")
	state.key("\r")
	if state.chosen != 2 {
		t.Fatalf("down twice + enter chose %d", state.chosen)
	}

	state = newSelector([]string{"main", "feature/login", "fix/login-crash", "release"})
	state.key("\x1b[A") // wraps to the last row
	if state.matches[state.cursor] != 3 {
		t.Fatalf("up from top landed on %d", state.matches[state.cursor])
	}
	for _, key := range []string{"l", "o", "g", " ", "f", "i"} {
		state.key(key)
	}
	state.key("\r")
	if state.chosen != 2 {
		t.Fatalf("filter 'log fi' chose %d", state.chosen)
	}

	state = newSelector([]string{"a", "b"})
	state.key("zz")
	state.key("\r") // nothing matches: enter does nothing
	if state.finished {
		t.Fatal("enter with no match should not finish")
	}
	state.key("\x7f")
	state.key("\x7f")
	state.key("\x1b")
	if !state.finished || state.chosen != -1 {
		t.Fatal("esc should cancel")
	}
}

func TestSelectorScrollsLongLists(t *testing.T) {
	labels := make([]string, 30)
	for index := range labels {
		labels[index] = string(rune('a' + index%26))
	}
	state := newSelector(labels)
	for range 15 {
		state.key("\x1b[B")
	}
	if state.offset != 15-selectorRows+1 {
		t.Fatalf("offset %d", state.offset)
	}
	if lines := state.render("Pick", 80); len(lines) != 1+1+selectorRows+1+1 {
		t.Fatalf("rendered %d lines", len(lines))
	}
}
