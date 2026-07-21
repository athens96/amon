package session

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Codex CLI rollout 로그 → 세션 기록 (맥 SessionHistoryScanner 이식).
//
// 누적 토큰은 파일별 **마지막 total_token_usage 스냅샷**만 쓴다(라인 합산 금지,
// internal/scan 과 동일). cached_input_tokens 는 input 의 부분집합이라 분리한다.

// codexSkippedPrefixes — 사람이 친 메시지가 아닌 주입 텍스트.
var codexSkippedPrefixes = []string{
	"# AGENTS.md instructions",
	"<INSTRUCTIONS>",
	"<environment_context>",
	"<permissions instructions>",
}

func codexIsRealUserMessage(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return false
	}
	for _, prefix := range codexSkippedPrefixes {
		if strings.HasPrefix(trimmed, prefix) {
			return false
		}
	}
	return true
}

// codexLine — rollout 한 줄에서 쓰는 필드만.
type codexLine struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	Payload   struct {
		Type    string          `json:"type"`
		ID      string          `json:"id"`      // session_meta
		Cwd     string          `json:"cwd"`     // session_meta · turn_context
		Model   string          `json:"model"`   // turn_context
		Message string          `json:"message"` // event_msg user_message
		Role    string          `json:"role"`    // response_item message
		Text    string          `json:"text"`    // response_item 구형
		Content json.RawMessage `json:"content"` // response_item message
		Info    *struct {
			Total *struct {
				Input  int64 `json:"input_tokens"`
				Cached int64 `json:"cached_input_tokens"`
				Output int64 `json:"output_tokens"`
				Total  int64 `json:"total_tokens"`
			} `json:"total_token_usage"`
		} `json:"info"`
	} `json:"payload"`
}

// codexBlock — response_item content 배열 요소.
type codexBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// codexUserMessage — response_item(role=user)의 input_text 중 진짜 사용자 메시지.
func codexUserMessage(line codexLine) string {
	if line.Payload.Type != "message" || line.Payload.Role != "user" {
		return ""
	}
	var blocks []codexBlock
	if json.Unmarshal(line.Payload.Content, &blocks) != nil {
		return ""
	}
	for _, b := range blocks {
		if b.Type == "input_text" && codexIsRealUserMessage(b.Text) {
			return b.Text
		}
	}
	return ""
}

// codexAssistantText — response_item(role=assistant)의 output_text/text 블록.
func codexAssistantText(line codexLine) string {
	if line.Payload.Type != "message" || line.Payload.Role != "assistant" {
		return ""
	}
	var blocks []codexBlock
	if json.Unmarshal(line.Payload.Content, &blocks) == nil {
		var texts []string
		for _, b := range blocks {
			if (b.Type == "output_text" || b.Type == "text") && b.Text != "" {
				texts = append(texts, b.Text)
			}
		}
		if len(texts) > 0 {
			return strings.Join(texts, " ")
		}
	}
	return line.Payload.Text
}

// parseCodexRollout — rollout 파일 하나 → 기록(세션이 아니면 nil).
func parseCodexRollout(path string) *Record {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var (
		sessionID, cwd, model, lastResult string
		first, last                       time.Time
		input, cached, output, total      int64
		hasUsage                          bool
		prompts                           []string
		promptCount                       int
		seenPrompts                       = map[string]struct{}{}
	)
	appendPrompt := func(text string) {
		fl := firstLine(text, 120)
		if fl == "" {
			return
		}
		if _, dup := seenPrompts[fl]; dup {
			return
		}
		seenPrompts[fl] = struct{}{}
		prompts = append(prompts, fl)
		if len(prompts) > MaxPrompts {
			prompts = prompts[len(prompts)-MaxPrompts:]
		}
		promptCount++
	}

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		var line codexLine
		if json.Unmarshal(sc.Bytes(), &line) != nil {
			continue
		}
		if ts, ok := parseISO(line.Timestamp); ok {
			if first.IsZero() {
				first = ts
			}
			last = ts
		}
		switch line.Type {
		case "session_meta":
			if line.Payload.ID != "" {
				sessionID = line.Payload.ID
			}
			if line.Payload.Cwd != "" {
				cwd = line.Payload.Cwd
			}
		case "turn_context":
			if line.Payload.Cwd != "" {
				cwd = line.Payload.Cwd
			}
			if line.Payload.Model != "" {
				model = line.Payload.Model
			}
		case "event_msg":
			switch line.Payload.Type {
			case "token_count":
				if line.Payload.Info == nil || line.Payload.Info.Total == nil {
					break
				}
				t := line.Payload.Info.Total
				input, cached, output = t.Input, t.Cached, t.Output
				total = t.Total
				if total == 0 {
					total = t.Input + t.Output
				}
				hasUsage = true
			case "user_message":
				appendPrompt(line.Payload.Message)
			}
		case "response_item":
			if text := codexUserMessage(line); text != "" {
				appendPrompt(text)
			} else if text := codexAssistantText(line); text != "" {
				if fl := firstLine(text, 200); fl != "" {
					lastResult = fl
				}
			}
		}
	}

	if sessionID == "" || first.IsZero() || last.IsZero() || !hasUsage || total <= 0 {
		return nil
	}
	if model == "" {
		model = "unknown" // 구버전 rollout 은 turn_context 가 없다
	}
	rec := Record{
		Provider:     "codex",
		SessionID:    sessionID,
		ProjectLabel: filepath.Base(cwd),
		// gitBranch — rollout 로그엔 브랜치 정보가 없다.
		StartedAt:    first,
		EndedAt:      last,
		Prompts:      prompts,
		PromptCount:  promptCount,
		LastResult:   lastResult,
		InputTokens:  maxInt64(0, input-cached),
		OutputTokens: output,
		CacheTokens:  cached,
		TotalTokens:  total,
		Models:       map[string]int64{model: total},
		SourcePath:   path,
	}
	if cwd == "" {
		rec.ProjectLabel = ""
	}
	if len(prompts) > 0 {
		rec.CurrentTask = prompts[len(prompts)-1]
	}
	return &rec
}

// ScanCodex — <root>/**/rollout-*.jsonl 에서 최근 세션을 만든다.
// 진행 중인 rollout 도 읽어 대시보드에 즉시 표시하고 다음 스캔에서 갱신한다.
func ScanCodex(root string, cache *FileCache) []Record {
	type candidate struct {
		path  string
		mtime time.Time
	}
	var files []candidate
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".jsonl") ||
			!strings.HasPrefix(filepath.Base(path), "rollout-") {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		files = append(files, candidate{path: path, mtime: info.ModTime()})
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return files[i].mtime.After(files[j].mtime) })
	if len(files) > SessionLimit {
		files = files[:SessionLimit]
	}

	visited := map[string]struct{}{}
	var records []Record
	for _, file := range files {
		key := "codex:" + file.path
		visited[key] = struct{}{}
		signature := fileSetSignature([]string{file.path})
		if entry, ok := cache.get(key, signature); ok {
			if entry.Record != nil {
				records = append(records, *entry.Record)
			}
			continue
		}
		rec := parseCodexRollout(file.path)
		cache.put(key, &CacheEntry{Signature: signature, Record: rec})
		if rec != nil {
			records = append(records, *rec)
		}
	}
	cache.sweep("codex:", visited)
	return records
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
