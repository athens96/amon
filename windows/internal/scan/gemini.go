package scan

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Gemini CLI 세션 로그 스캐너 (agentsview parser 규칙 이식, SPEC §2-2).
//
// 파일: <tmp>/<hash>/chats/session-*.json | session-*.jsonl.
//   - JSON 오브젝트 파일: {sessionId, startTime, lastUpdated, messages:[...]}
//   - JSONL 파일: sessionId 있는 라인이 세션 헤더, type 있는 라인이 메시지.
//     같은 메시지 id 는 last-wins (세션 진행 중 append 되며 갱신될 수 있음).
// 매핑: input=tokens.input(캐시 제외분), cacheRead=tokens.cached,
//   output=tokens.output+tokens.thoughts, reasoning=tokens.thoughts, cacheWrite=0.
// 모델=message.model, 세션 수=고유 sessionId.

// geminiTokens — 메시지 tokens 블록.
type geminiTokens struct {
	Input    int64 `json:"input"`
	Output   int64 `json:"output"`
	Cached   int64 `json:"cached"`
	Thoughts int64 `json:"thoughts"`
}

// geminiMessage — 한 메시지 (JSON object · JSONL 공통 필드).
type geminiMessage struct {
	ID        string        `json:"id"`
	Type      string        `json:"type"` // "user" | "gemini"
	Timestamp string        `json:"timestamp"`
	Model     string        `json:"model"`
	Tokens    *geminiTokens `json:"tokens"`
}

// geminiObject — 오브젝트 형식 파일 루트.
type geminiObject struct {
	SessionID string          `json:"sessionId"`
	Messages  []geminiMessage `json:"messages"`
}

// geminiLine — JSONL 한 라인(세션 헤더 또는 메시지). 헤더는 sessionId 를, 메시지는 type 을 가진다.
type geminiLine struct {
	SessionID string `json:"sessionId"`
	geminiMessage
}

// ScanGemini — <tmp> 아래 session-* 파일을 스캔한다.
func ScanGemini(root string, windowStart time.Time) ToolSummary {
	s := ToolSummary{
		Tool: "gemini", DisplayName: "Gemini CLI",
		Daily: map[string]TokenUsage{}, Models: map[string]int64{},
		DailyByModel: map[string]map[string]TokenUsage{}, PathExists: true,
	}
	if !dirExists(root) {
		s.PathExists = false
		s.Note = "경로를 찾을 수 없습니다"
		return s
	}

	scanWalkFiles(&s, root, windowStart, scanCache.gemini, geminiMatch, parseGeminiFile)

	if s.Sessions == 0 {
		s.Note = "세션 로그가 없습니다"
	}
	return s
}

// geminiMatch — session-*.json | session-*.jsonl 파일만.
func geminiMatch(base string) bool {
	return strings.HasPrefix(base, "session-") &&
		(strings.HasSuffix(base, ".json") || strings.HasSuffix(base, ".jsonl"))
}

// parseGeminiFile — 파일 하나를 파싱해 캐시 엔트리를 만든다. 열기 실패 시 nil.
func parseGeminiFile(path string, windowStart time.Time) *toolFileEntry {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	e := newToolFileEntry()
	fallback := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))

	// 오브젝트 형식: 파일 전체가 유효 JSON 이고 messages 또는 sessionId 를 가진다.
	// (단일 라인 JSONL 헤더도 여기로 들어오지만 messages 가 없어 0-메시지 세션이 된다 — 동일 결과.)
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) > 0 && trimmed[0] == '{' && json.Valid(trimmed) {
		var obj geminiObject
		if json.Unmarshal(trimmed, &obj) == nil && (len(obj.Messages) > 0 || obj.SessionID != "") {
			sid := obj.SessionID
			if sid == "" {
				sid = fallback
			}
			e.sessionIDs = append(e.sessionIDs, sid)
			applyGeminiMessages(e, obj.Messages, windowStart)
			return e
		}
	}

	parseGeminiJSONL(e, data, fallback, windowStart)
	return e
}

// parseGeminiJSONL — 라인별 레코드. 메시지 id 는 등장 위치를 유지한 채 last-wins,
// 세션 헤더에서 sessionId 를 얻는다. 델타 계산이 순서에 의존하므로 등장 순서를 보존한다.
func parseGeminiJSONL(e *toolFileEntry, data []byte, fallback string, windowStart time.Time) {
	var sessionID string
	var records []geminiMessage
	recordIDs := map[string]int{}

	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 || !json.Valid(line) {
			continue
		}
		var gl geminiLine
		if json.Unmarshal(line, &gl) != nil {
			continue
		}
		if gl.SessionID != "" && sessionID == "" {
			sessionID = gl.SessionID
		}
		if gl.Type != "user" && gl.Type != "gemini" {
			continue
		}
		m := gl.geminiMessage
		if m.ID != "" {
			if idx, ok := recordIDs[m.ID]; ok {
				records[idx] = m // last-wins, 위치 유지
				continue
			}
			recordIDs[m.ID] = len(records)
		}
		records = append(records, m)
	}

	if sessionID == "" {
		sessionID = fallback
	}
	e.sessionIDs = append(e.sessionIDs, sessionID)
	applyGeminiMessages(e, records, windowStart)
}

// applyGeminiMessages — 세션 파일 순서대로 누적 델타를 적용해 엔트리에 귀속한다.
//
// gemini 의 tokens.input/cached 는 그 시점까지의 누적 컨텍스트값이므로 이전 tokens-보유
// 메시지 대비 증분만 실제 소비다(agentsview applyGeminiCumulativeDeltas, SPEC §2-2 v1.1):
//   - inputDelta  = tokens.input  - prevInput  (음수면 카운터 리셋 → = tokens.input)
//   - cachedDelta = tokens.cached - prevCached (음수면 → = tokens.cached)
//   - output/thoughts 는 메시지별 값 그대로, reasoning=thoughts, cacheWrite=0
//   - prev 는 tokens 를 가진 메시지에서만 전진(소비 0 이어도 전진)
func applyGeminiMessages(e *toolFileEntry, msgs []geminiMessage, windowStart time.Time) {
	var prevInput, prevCached int64
	for _, m := range msgs {
		if m.Type != "gemini" || m.Tokens == nil {
			continue
		}
		tok := m.Tokens
		inputDelta := tok.Input - prevInput
		if inputDelta < 0 {
			inputDelta = tok.Input
		}
		cachedDelta := tok.Cached - prevCached
		if cachedDelta < 0 {
			cachedDelta = tok.Cached
		}
		prevInput = tok.Input
		prevCached = tok.Cached

		output := tok.Output + tok.Thoughts
		total := inputDelta + output + cachedDelta // cacheWrite=0
		if total == 0 {
			continue // prev 는 이미 전진 — 이 메시지의 소비는 없음
		}
		e.add(TokenUsage{
			Input:     inputDelta,
			Output:    output,
			CacheRead: cachedDelta,
			Reasoning: tok.Thoughts,
			Total:     total,
		}, m.Model, parseGeminiTime(m.Timestamp), windowStart)
	}
}

// parseGeminiTime — ISO8601(밀리초 포함) 타임스탬프 파싱. 실패 시 zero.
func parseGeminiTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t
	}
	return time.Time{}
}
