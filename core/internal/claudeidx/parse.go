// Package claudeidx indexes Claude Code transcripts (~/.claude/projects/*/*.jsonl).
package claudeidx

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const firstPromptMax = 120

// Session is the summary of one transcript file.
type Session struct {
	ID          string    `json:"id"`
	Path        string    `json:"path"`
	Cwd         string    `json:"cwd"`
	Branches    []string  `json:"branches"` // order of first appearance
	LastBranch  string    `json:"last_branch"`
	CustomTitle string    `json:"custom_title,omitempty"`
	AITitle     string    `json:"ai_title,omitempty"`
	FirstPrompt string    `json:"first_prompt,omitempty"`
	Start       time.Time `json:"start"`
	Last        time.Time `json:"last"`
	Prompts     int       `json:"prompts"`
	EndedTurn   bool      `json:"ended_turn"` // last main-thread message is an assistant end_turn
	Size        int64     `json:"size"`
	ModTime     int64     `json:"mod_time"`
	Offset      int64     `json:"offset"` // bytes parsed so far (for incremental updates)
}

// Title picks the best human label: custom title, then AI title, then first prompt.
func (session Session) Title() string {
	switch {
	case session.CustomTitle != "":
		return session.CustomTitle
	case session.AITitle != "":
		return session.AITitle
	case session.FirstPrompt != "":
		return session.FirstPrompt
	}
	return "(untitled)"
}

type rawMessage struct {
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content"`
	StopReason string          `json:"stop_reason"`
}

type rawLine struct {
	Type        string      `json:"type"`
	Cwd         string      `json:"cwd"`
	GitBranch   string      `json:"gitBranch"`
	Timestamp   string      `json:"timestamp"`
	IsSidechain bool        `json:"isSidechain"`
	IsMeta      bool        `json:"isMeta"`
	CustomTitle string      `json:"customTitle"`
	AITitle     string      `json:"aiTitle"`
	Message     *rawMessage `json:"message"`
}

// Lines with these prefixes are large and carry nothing we index.
var skipPrefixes = [][]byte{
	[]byte(`{"type":"api-request`),
	[]byte(`{"type":"attachment"`),
	[]byte(`{"type":"file-history-snapshot"`),
}

// ParseFile reads one transcript and summarizes it.
func ParseFile(path string) (Session, error) {
	return parseFileFrom(Session{}, path)
}

// parseFileFrom continues parsing from session.Offset when the file only grew; otherwise starts over.
func parseFileFrom(previous Session, path string) (Session, error) {
	file, err := os.Open(path)
	if err != nil {
		return Session{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Session{}, err
	}
	session := previous
	if session.Offset <= 0 || session.Offset > info.Size() {
		session = Session{}
	}
	if _, err := file.Seek(session.Offset, io.SeekStart); err != nil {
		return Session{}, err
	}
	consumed, err := session.consume(file)
	if err != nil {
		return Session{}, err
	}
	session.Offset += consumed
	session.ID = strings.TrimSuffix(filepath.Base(path), ".jsonl")
	session.Path = path
	session.Size = info.Size()
	session.ModTime = info.ModTime().UnixNano()
	session.readSidecarTitle()
	return session, nil
}

// readSidecarTitle prefers <id>/custom-title.json, where Claude keeps the latest rename.
func (session *Session) readSidecarTitle() {
	data, err := os.ReadFile(filepath.Join(strings.TrimSuffix(session.Path, ".jsonl"), "custom-title.json"))
	if err != nil {
		return
	}
	var sidecar struct {
		CustomTitle string `json:"customTitle"`
	}
	if json.Unmarshal(data, &sidecar) == nil && sidecar.CustomTitle != "" {
		session.CustomTitle = sidecar.CustomTitle
	}
}

// Parse summarizes a complete transcript stream.
func Parse(reader io.Reader) (Session, error) {
	var session Session
	_, err := session.consume(reader)
	return session, err
}

// consume applies complete lines and returns the bytes consumed (a trailing partial line is left
// unread so the next incremental pass picks it up once it is complete).
func (session *Session) consume(reader io.Reader) (int64, error) {
	buffered := bufio.NewReaderSize(reader, 256*1024)
	var consumed int64
	var long []byte
	for {
		chunk, err := buffered.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			long = append(long, chunk...)
			continue
		}
		line := chunk
		if len(long) > 0 {
			long = append(long, chunk...)
			line = long
		}
		if err == io.EOF {
			// Final line without newline: apply only if it is valid JSON (complete).
			if trimmed := bytes.TrimSpace(line); len(trimmed) > 0 && json.Valid(trimmed) {
				session.apply(trimmed)
				consumed += int64(len(line))
			}
			return consumed, nil
		}
		if err != nil {
			return consumed, err
		}
		consumed += int64(len(line))
		if trimmed := bytes.TrimSpace(line); len(trimmed) > 0 {
			session.apply(trimmed)
		}
		long = long[:0]
	}
}

func (session *Session) apply(line []byte) {
	for _, prefix := range skipPrefixes {
		if bytes.HasPrefix(line, prefix) {
			return
		}
	}
	var entry rawLine
	if json.Unmarshal(line, &entry) != nil {
		return
	}
	switch entry.Type {
	case "custom-title":
		session.CustomTitle = entry.CustomTitle
		return
	case "ai-title":
		session.AITitle = entry.AITitle
		return
	case "user", "assistant":
	default:
		return
	}
	if entry.IsSidechain {
		return
	}
	if entry.Cwd != "" {
		session.Cwd = entry.Cwd
	}
	if entry.GitBranch != "" && entry.GitBranch != "HEAD" {
		session.LastBranch = entry.GitBranch
		if !slices.Contains(session.Branches, entry.GitBranch) {
			session.Branches = append(session.Branches, entry.GitBranch)
		}
	}
	if stamp, err := time.Parse(time.RFC3339Nano, entry.Timestamp); err == nil {
		if session.Start.IsZero() {
			session.Start = stamp
		}
		session.Last = stamp
	}
	if entry.Message == nil {
		return
	}
	if entry.Type == "assistant" {
		session.EndedTurn = entry.Message.StopReason == "end_turn"
		return
	}
	session.EndedTurn = false
	if entry.IsMeta {
		return
	}
	if text := humanText(entry.Message.Content); text != "" {
		session.Prompts++
		if session.FirstPrompt == "" {
			session.FirstPrompt = truncate(text, firstPromptMax)
		}
	}
}

// humanText returns typed user text, ignoring tool results and harness-injected tags.
func humanText(content json.RawMessage) string {
	var text string
	if json.Unmarshal(content, &text) != nil {
		var blocks []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if json.Unmarshal(content, &blocks) != nil {
			return ""
		}
		for _, block := range blocks {
			if block.Type == "tool_result" {
				return ""
			}
			if block.Type == "text" && text == "" {
				text = block.Text
			}
		}
	}
	text = strings.TrimSpace(text)
	if strings.HasPrefix(text, "<") || strings.HasPrefix(text, "[Request interrupted") {
		return ""
	}
	return text
}

func truncate(text string, max int) string {
	text = strings.Join(strings.Fields(text), " ")
	runes := []rune(text)
	if len(runes) <= max {
		return text
	}
	return string(runes[:max-1]) + "…"
}
