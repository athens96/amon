package session

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Claude Code 트랜스크립트 → 세션 기록 (맥 SessionHistoryScanner 이식).
//
// 토큰 dedup 규칙은 internal/scan 과 동일 — 한 API 응답이 콘텐츠 블록마다
// 반복 기록되므로 (message.id, requestId) 단위 last-wins (안 하면 ~2.4배 과대).

// nonPromptPrefixes — 사람이 친 프롬프트가 아닌 주입 텍스트(맥 훅 스크립트와
// 동일 규칙 유지).
var nonPromptPrefixes = []string{
	"<command-", "<local-command", "<system-reminder", "<user-prompt-submit-hook",
}

// claudeLine — 트랜스크립트 한 줄에서 쓰는 필드만.
type claudeLine struct {
	Type         string `json:"type"`
	Timestamp    string `json:"timestamp"`
	IsSidechain  bool   `json:"isSidechain"`
	PromptSource string `json:"promptSource"`
	RequestID    string `json:"requestId"`
	Cwd          string `json:"cwd"`
	GitBranch    string `json:"gitBranch"`
	Message      *struct {
		ID      string          `json:"id"`
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
		Usage   *struct {
			Input      int64 `json:"input_tokens"`
			Output     int64 `json:"output_tokens"`
			CacheWrite int64 `json:"cache_creation_input_tokens"`
			CacheRead  int64 `json:"cache_read_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

// contentBlock — message.content 배열 요소에서 쓰는 필드만.
type contentBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
	Name string `json:"name"` // tool_use 의 툴 이름
}

// decodeContent — content 는 문자열 또는 블록 배열 양쪽 형태가 있다.
func decodeContent(raw json.RawMessage) (text string, blocks []contentBlock, isString bool) {
	if len(raw) == 0 {
		return "", nil, false
	}
	if raw[0] == '"' {
		if json.Unmarshal(raw, &text) == nil {
			return text, nil, true
		}
		return "", nil, false
	}
	_ = json.Unmarshal(raw, &blocks)
	return "", blocks, false
}

// assistantText — 어시스턴트 응답에서 사람이 읽는 text 블록만 (맥과 동일: 공백 join).
func assistantText(raw json.RawMessage) string {
	text, blocks, isString := decodeContent(raw)
	if isString {
		return text
	}
	var texts []string
	for _, b := range blocks {
		if b.Type == "text" && b.Text != "" {
			texts = append(texts, b.Text)
		}
	}
	return strings.Join(texts, " ")
}

// promptText — 사용자가 실제로 타이핑한 텍스트만. tool_result 턴과 주입 텍스트 제외.
func promptText(raw json.RawMessage) string {
	text, blocks, isString := decodeContent(raw)
	if isString {
		if isRealPrompt(text) {
			return text
		}
		return ""
	}
	for _, b := range blocks {
		if b.Type == "tool_result" {
			return ""
		}
	}
	for _, b := range blocks {
		if b.Type == "text" && isRealPrompt(b.Text) {
			return b.Text
		}
	}
	return ""
}

func isRealPrompt(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return false
	}
	for _, prefix := range nonPromptPrefixes {
		if strings.HasPrefix(trimmed, prefix) {
			return false
		}
	}
	return true
}

// agentToolUses — 서브에이전트를 띄우는 tool_use 블록 수(툴 이름은 Agent/Task).
func agentToolUses(raw json.RawMessage) int {
	_, blocks, _ := decodeContent(raw)
	n := 0
	for _, b := range blocks {
		if b.Type == "tool_use" && (b.Name == "Agent" || b.Name == "Task") {
			n++
		}
	}
	return n
}

// parseISO — RFC3339(소수초 유무 모두)를 견딘다.
func parseISO(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// claudeTranscript — 트랜스크립트 한 세션에서 뽑아내는 모든 것.
type claudeTranscript struct {
	input, output, cacheRead, cacheWrite int64
	models                               map[string]int64
	prompts                              []string
	promptCount                          int
	lastResult                           string
	first, last                          time.Time
	cwd, gitBranch                       string
	agentCount                           int
}

// usage 라인 프리필터 — 서브에이전트 파일은 usage 있는 라인만 파싱한다.
var usageToken = []byte(`"usage"`)

type claudeUsageEntry struct {
	input, output, cacheWrite, cacheRead int64
	model                                string
}

// parseClaudeSession — 본 세션 + 서브에이전트 트랜스크립트를 훑어 요약을 만든다.
func parseClaudeSession(transcriptPath string) claudeTranscript {
	out := claudeTranscript{models: map[string]int64{}}
	byMessage := map[string]*claudeUsageEntry{}

	parseClaudeMain(transcriptPath, &out, byMessage)
	for _, file := range subagentTranscripts(transcriptPath) {
		parseClaudeUsageOnly(file, byMessage)
	}

	for _, e := range byMessage {
		out.input += e.input
		out.output += e.output
		out.cacheRead += e.cacheRead
		out.cacheWrite += e.cacheWrite
		total := e.input + e.output + e.cacheRead + e.cacheWrite
		if total > 0 && e.model != "" && e.model != "<synthetic>" {
			out.models[e.model] += total
		}
	}
	out.promptCount = len(out.prompts)
	if len(out.prompts) > MaxPrompts {
		out.prompts = out.prompts[len(out.prompts)-MaxPrompts:]
	}
	return out
}

// subagentTranscripts — <projects>/<session>.jsonl 옆의 <session>/subagents/*.jsonl.
func subagentTranscripts(transcriptPath string) []string {
	sessionID := strings.TrimSuffix(filepath.Base(transcriptPath), ".jsonl")
	dir := filepath.Join(filepath.Dir(transcriptPath), sessionID, "subagents")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".jsonl") {
			out = append(out, filepath.Join(dir, e.Name()))
		}
	}
	return out
}

func absorbClaudeUsage(line claudeLine, byMessage map[string]*claudeUsageEntry) {
	if line.Type != "assistant" || line.Message == nil || line.Message.Usage == nil {
		return
	}
	key := line.Message.ID + "|" + line.RequestID
	u := line.Message.Usage
	entry := &claudeUsageEntry{
		input: u.Input, output: u.Output,
		cacheWrite: u.CacheWrite, cacheRead: u.CacheRead,
		model: line.Message.Model,
	}
	byMessage[key] = entry // last-wins
}

func parseClaudeMain(path string, out *claudeTranscript, byMessage map[string]*claudeUsageEntry) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		var line claudeLine
		if json.Unmarshal(sc.Bytes(), &line) != nil {
			continue
		}
		if ts, ok := parseISO(line.Timestamp); ok {
			if out.first.IsZero() {
				out.first = ts
			}
			out.last = ts
		}
		if out.cwd == "" {
			out.cwd = line.Cwd
		}
		if out.gitBranch == "" {
			out.gitBranch = line.GitBranch
		}

		switch line.Type {
		case "assistant":
			absorbClaudeUsage(line, byMessage)
			if line.IsSidechain || line.Message == nil {
				break
			}
			out.agentCount += agentToolUses(line.Message.Content)
			if text := assistantText(line.Message.Content); text != "" {
				if fl := firstLine(text, 200); fl != "" {
					out.lastResult = fl
				}
			}
		case "user":
			// 사람이 직접 타이핑한 프롬프트만 — 훅 주입·스킬 출력 라인엔
			// promptSource 가 없거나 "system" 이다(맥에서 전 트랜스크립트 실측).
			if line.IsSidechain || line.PromptSource != "typed" || line.Message == nil {
				break
			}
			if text := promptText(line.Message.Content); text != "" {
				if fl := firstLine(text, 120); fl != "" {
					out.prompts = append(out.prompts, fl)
				}
			}
		}
	}
}

// parseClaudeUsageOnly — 서브에이전트 파일은 토큰만 필요하다(프리필터로 파싱 절약).
func parseClaudeUsageOnly(path string, byMessage map[string]*claudeUsageEntry) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		raw := sc.Bytes()
		if !bytes.Contains(raw, usageToken) {
			continue
		}
		var line claudeLine
		if json.Unmarshal(raw, &line) != nil {
			continue
		}
		absorbClaudeUsage(line, byMessage)
	}
}

// ScanClaude — <root>/<project>/<session>.jsonl 을 훑어 최근 세션을 만든다.
// 진행 중인 파일도 안전하게 읽어 대시보드에 즉시 표시하고 다음 스캔에서 갱신한다.
func ScanClaude(root string, cache *FileCache) []Record {
	projects, err := os.ReadDir(root)
	if err != nil {
		return nil
	}

	type candidate struct {
		path  string
		mtime time.Time
	}
	var files []candidate
	for _, project := range projects {
		if !project.IsDir() {
			continue
		}
		entries, err := os.ReadDir(filepath.Join(root, project.Name()))
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			files = append(files, candidate{
				path:  filepath.Join(root, project.Name(), e.Name()),
				mtime: info.ModTime(),
			})
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mtime.After(files[j].mtime) })
	if len(files) > SessionLimit {
		files = files[:SessionLimit]
	}

	visited := map[string]struct{}{}
	var records []Record
	for _, file := range files {
		key := "claude:" + file.path
		visited[key] = struct{}{}
		signature := fileSetSignature(append([]string{file.path}, subagentTranscripts(file.path)...))
		if entry, ok := cache.get(key, signature); ok {
			if entry.Record != nil {
				records = append(records, *entry.Record)
			}
			continue
		}

		parsed := parseClaudeSession(file.path)
		total := parsed.input + parsed.output + parsed.cacheRead + parsed.cacheWrite
		if parsed.first.IsZero() || parsed.last.IsZero() || (total == 0 && len(parsed.prompts) == 0) {
			cache.put(key, &CacheEntry{Signature: signature})
			continue
		}

		rec := Record{
			Provider:     "claude",
			SessionID:    strings.TrimSuffix(filepath.Base(file.path), ".jsonl"),
			ProjectLabel: filepath.Base(parsed.cwd),
			GitBranch:    parsed.gitBranch,
			StartedAt:    parsed.first,
			EndedAt:      parsed.last,
			Prompts:      parsed.prompts,
			PromptCount:  parsed.promptCount,
			LastResult:   parsed.lastResult,
			InputTokens:  parsed.input,
			OutputTokens: parsed.output,
			CacheTokens:  parsed.cacheRead + parsed.cacheWrite,
			TotalTokens:  total,
			Models:       parsed.models,
			AgentCount:   parsed.agentCount,
			SourcePath:   file.path,
		}
		if len(rec.Prompts) > 0 {
			rec.CurrentTask = rec.Prompts[len(rec.Prompts)-1]
		}
		if parsed.cwd == "" {
			rec.ProjectLabel = ""
		}
		cache.put(key, &CacheEntry{Signature: signature, Record: &rec})
		records = append(records, rec)
	}
	cache.sweep("claude:", visited)
	return records
}
