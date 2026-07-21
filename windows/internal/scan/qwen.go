package scan

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"time"
)

// Qwen Code 세션 로그 스캐너 (agentsview parser 규칙 이식, SPEC §2-2).
//
// 파일: <projects>/**/*.jsonl (Claude Code 와 같은 projects 레이아웃, 보통 <proj>/chats/<stem>.jsonl).
// type=="assistant" 라인의 usageMetadata 만 본다.
// 매핑: cacheRead=cachedContentTokenCount,
//   input=promptTokenCount-cachedContentTokenCount(prompt 는 캐시 포함),
//   output=candidatesTokenCount+thoughtsTokenCount, reasoning=thoughtsTokenCount, cacheWrite=0.
// 턴 내 tool-call 반복 라인마다 usageMetadata 가 반복되면 라인 단위로 그대로 합산한다
// (각 호출이 별개 과금 — agentsview 도 iteration 별 usage 를 전부 합산). 세션 수=고유 .jsonl 파일.

// qwenUsageMetadata — assistant 라인의 usageMetadata 블록.
type qwenUsageMetadata struct {
	Prompt     int64 `json:"promptTokenCount"`
	Candidates int64 `json:"candidatesTokenCount"`
	Cached     int64 `json:"cachedContentTokenCount"`
	Thoughts   int64 `json:"thoughtsTokenCount"`
}

// qwenLine — JSONL 한 라인. 모델은 루트 또는 message.model 에 올 수 있다(실데이터는 루트).
type qwenLine struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	Model     string `json:"model"`
	Message   struct {
		Model string `json:"model"`
	} `json:"message"`
	Usage *qwenUsageMetadata `json:"usageMetadata"`
}

// qwenUsageToken — 라인 프리필터 (usageMetadata 없는 라인은 JSON 파싱 생략).
var qwenUsageToken = []byte(`"usageMetadata"`)

// ScanQwen — <projects> 아래 *.jsonl 을 스캔한다.
func ScanQwen(root string, windowStart time.Time) ToolSummary {
	s := ToolSummary{
		Tool: "qwen", DisplayName: "Qwen Code",
		Daily: map[string]TokenUsage{}, Models: map[string]int64{},
		DailyByModel: map[string]map[string]TokenUsage{}, PathExists: true,
	}
	if !dirExists(root) {
		s.PathExists = false
		s.Note = "경로를 찾을 수 없습니다"
		return s
	}

	scanWalkFiles(&s, root, windowStart, scanCache.qwen, qwenMatch, parseQwenFile)

	if s.Sessions == 0 {
		s.Note = "세션 로그가 없습니다"
	}
	return s
}

// qwenMatch — *.jsonl (숨김 파일 제외).
func qwenMatch(base string) bool {
	return strings.HasSuffix(base, ".jsonl") && !strings.HasPrefix(base, ".")
}

// parseQwenFile — .jsonl 하나를 파싱해 캐시 엔트리를 만든다. 열기 실패 시 nil.
func parseQwenFile(path string, windowStart time.Time) *toolFileEntry {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	e := newToolFileEntry()
	e.sessionIDs = append(e.sessionIDs, path) // 세션 = 파일 단위

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if !bytes.Contains(line, qwenUsageToken) {
			continue
		}
		var ql qwenLine
		if json.Unmarshal(line, &ql) != nil || ql.Type != "assistant" || ql.Usage == nil {
			continue
		}
		um := ql.Usage
		input := um.Prompt - um.Cached // prompt 는 캐시 포함
		if input < 0 {
			input = 0
		}
		output := um.Candidates + um.Thoughts
		total := input + output + um.Cached // cacheWrite=0
		if total == 0 {
			continue
		}
		u := TokenUsage{
			Input:     input,
			Output:    output,
			CacheRead: um.Cached,
			Reasoning: um.Thoughts,
			Total:     total,
		}
		model := ql.Model
		if model == "" {
			model = ql.Message.Model
		}
		if model == "" {
			model = "unknown"
		}
		e.add(u, model, parseGeminiTime(ql.Timestamp), windowStart)
	}
	return e
}
