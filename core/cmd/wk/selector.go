package main

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// Built-in arrow-key picker, used when fzf is not installed. ↑↓ (or ctrl-p/n) move, typing filters,
// enter picks, esc or ctrl-c cancels.

const selectorRows = 10

var ansiPattern = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(text string) string { return ansiPattern.ReplaceAllString(text, "") }

// selector is the picker's state, kept apart from the terminal so it can be tested.
type selector struct {
	labels   []string
	query    string
	matches  []int // indexes into labels
	cursor   int   // index into matches
	offset   int   // first visible match
	finished bool
	chosen   int // -1 when cancelled
}

func newSelector(labels []string) *selector {
	state := &selector{labels: labels, chosen: -1}
	state.filter()
	return state
}

func (state *selector) filter() {
	state.matches = state.matches[:0]
	words := strings.Fields(strings.ToLower(state.query))
	for index, label := range state.labels {
		plain := strings.ToLower(stripANSI(label))
		ok := true
		for _, word := range words {
			if !strings.Contains(plain, word) {
				ok = false
				break
			}
		}
		if ok {
			state.matches = append(state.matches, index)
		}
	}
	state.cursor, state.offset = 0, 0
}

func (state *selector) move(delta int) {
	if len(state.matches) == 0 {
		return
	}
	state.cursor = (state.cursor + delta + len(state.matches)) % len(state.matches)
	if state.cursor < state.offset {
		state.offset = state.cursor
	}
	if state.cursor >= state.offset+selectorRows {
		state.offset = state.cursor - selectorRows + 1
	}
}

// key applies one keypress (a raw byte sequence from the terminal).
func (state *selector) key(input string) {
	switch input {
	case "\x1b[A", "\x1bOA", "\x10": // up, ctrl-p
		state.move(-1)
	case "\x1b[B", "\x1bOB", "\x0e", "\t": // down, ctrl-n, tab
		state.move(1)
	case "\r", "\n":
		if len(state.matches) > 0 {
			state.chosen = state.matches[state.cursor]
			state.finished = true
		}
	case "\x1b", "\x03", "\x04": // esc, ctrl-c, ctrl-d
		state.finished = true
	case "\x7f", "\b":
		if state.query != "" {
			runes := []rune(state.query)
			state.query = string(runes[:len(runes)-1])
			state.filter()
		}
	case "\x15": // ctrl-u
		state.query = ""
		state.filter()
	default:
		if strings.HasPrefix(input, "\x1b") {
			return // other escape sequences (left/right, function keys)
		}
		printable := strings.Map(func(r rune) rune {
			if r < 32 {
				return -1
			}
			return r
		}, input)
		if printable != "" {
			state.query += printable
			state.filter()
		}
	}
}

func (state *selector) render(header string, width int) []string {
	lines := []string{header}
	if len(state.labels) > selectorRows || state.query != "" {
		lines = append(lines, dim("  filter: ")+state.query+"▏")
	}
	end := min(state.offset+selectorRows, len(state.matches))
	for position := state.offset; position < end; position++ {
		label := state.labels[state.matches[position]]
		if plain := stripANSI(label); len([]rune(plain)) > width-4 {
			label = string([]rune(plain)[:max(width-5, 1)]) + "…"
		}
		if position == state.cursor {
			lines = append(lines, cyan("❯ ")+bold(stripANSI(label)))
		} else {
			lines = append(lines, "  "+label)
		}
	}
	if len(state.matches) == 0 {
		lines = append(lines, dim("  no match"))
	} else if len(state.matches) > selectorRows {
		lines = append(lines, dim(fmt.Sprintf("  %d/%d", state.cursor+1, len(state.matches))))
	}
	lines = append(lines, dim("  ↑↓ move · type to filter · enter pick · esc cancel"))
	return lines
}

func canUseSelector() bool {
	return isTerminal(os.Stdin) && isTerminal(os.Stderr) && os.Getenv("TERM") != "dumb"
}

func stty(args ...string) (string, error) {
	cmd := exec.Command("stty", args...)
	cmd.Stdin = os.Stdin
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func terminalWidth() int {
	if size, err := stty("size"); err == nil {
		if fields := strings.Fields(size); len(fields) == 2 {
			if width, err := strconv.Atoi(fields[1]); err == nil && width > 20 {
				return width
			}
		}
	}
	return 80
}

// selectWithArrows shows labels and returns the chosen index, or errCancelled.
func selectWithArrows(header string, labels []string) (int, error) {
	saved, err := stty("-g")
	if err != nil {
		return -1, err
	}
	if _, err := stty("raw", "-echo"); err != nil {
		return -1, err
	}
	out := os.Stderr
	fmt.Fprint(out, "\x1b[?25l") // hide cursor
	defer func() {
		_, _ = stty(saved)
		fmt.Fprint(out, "\x1b[?25h")
	}()

	state := newSelector(labels)
	width := terminalWidth()
	drawn := 0
	buffer := make([]byte, 64)
	for {
		if drawn > 0 {
			fmt.Fprintf(out, "\r\x1b[%dA", drawn-1)
		}
		fmt.Fprint(out, "\r\x1b[J")
		lines := state.render(bold(header), width)
		fmt.Fprint(out, strings.Join(lines, "\r\n"))
		drawn = len(lines)
		if state.finished {
			break
		}
		count, err := os.Stdin.Read(buffer)
		if err != nil || count == 0 {
			state.finished = true
			continue
		}
		state.key(string(buffer[:count]))
	}
	// Collapse the picker to one summary line.
	fmt.Fprintf(out, "\r\x1b[%dA\x1b[J", drawn-1)
	if state.chosen < 0 {
		fmt.Fprint(out, bold(header)+" "+dim("cancelled")+"\r\n")
		return -1, errCancelled
	}
	fmt.Fprint(out, bold(header)+" "+stripANSI(labels[state.chosen])+"\r\n")
	return state.chosen, nil
}
