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

// Copilot CLI 세션 로그 스캐너 (agentsview parser 규칙 이식, SPEC §2-2).
//
// 파일: <session-state>/<uuid>.jsonl (구) 또는 <session-state>/<uuid>/events.jsonl (신).
// 같은 uuid 가 양쪽에 있으면 신형(디렉토리) 우선.
// type=="session.shutdown" 이벤트의 data.modelMetrics 만 본다
//   (modelKey → {usage:{inputTokens,cacheReadTokens,cacheWriteTokens,outputTokens,reasoningTokens}}).
// 매핑: input=max(inputTokens-cacheReadTokens-cacheWriteTokens,0) (inputTokens 는 캐시 포함 총량),
//   cacheRead/cacheWrite/output/reasoning 그대로. 일자=shutdown 이벤트 timestamp 의 로컬 일자.
// 한 파일에 shutdown 이 여러 번(재시작)이면 전부 합산. shutdown 없는 세션은 0. 세션 수=고유 uuid.

// copilotUsage — modelMetrics[model].usage.
type copilotUsage struct {
	InputTokens      int64 `json:"inputTokens"`
	CacheReadTokens  int64 `json:"cacheReadTokens"`
	CacheWriteTokens int64 `json:"cacheWriteTokens"`
	OutputTokens     int64 `json:"outputTokens"`
	ReasoningTokens  int64 `json:"reasoningTokens"`
}

// copilotEvent — JSONL 이벤트. shutdown 이벤트만 의미가 있다.
type copilotEvent struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	Data      struct {
		ModelMetrics map[string]struct {
			Usage copilotUsage `json:"usage"`
		} `json:"modelMetrics"`
	} `json:"data"`
}

// copilotShutdownToken — 라인 프리필터 (shutdown 없는 라인은 JSON 파싱 생략).
var copilotShutdownToken = []byte(`"session.shutdown"`)

// ScanCopilot — <session-state> 아래 세션(디렉토리/플랫)을 스캔한다.
func ScanCopilot(root string, windowStart time.Time) ToolSummary {
	s := ToolSummary{
		Tool: "copilot", DisplayName: "Copilot CLI",
		Daily: map[string]TokenUsage{}, Models: map[string]int64{},
		DailyByModel: map[string]map[string]TokenUsage{}, PathExists: true,
	}
	if !dirExists(root) {
		s.PathExists = false
		s.Note = "경로를 찾을 수 없습니다"
		return s
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		s.Note = "session-state 를 읽을 수 없습니다"
		return s
	}

	// uuid → events 파일 경로. 디렉토리(신형)가 있으면 그 uuid 의 플랫 파일은 무시한다.
	paths := map[string]string{}
	fromDir := map[string]bool{}
	for _, ent := range entries {
		if ent.IsDir() {
			ep := filepath.Join(root, ent.Name(), "events.jsonl")
			if fileExists(ep) {
				paths[ent.Name()] = ep
				fromDir[ent.Name()] = true
			}
		}
	}
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		if stem, ok := strings.CutSuffix(ent.Name(), ".jsonl"); ok && !fromDir[stem] {
			paths[stem] = filepath.Join(root, ent.Name())
		}
	}

	sessions := map[string]struct{}{}
	visited := map[string]struct{}{}
	windowKey := DayKey(windowStart)

	scanCache.Lock()
	defer scanCache.Unlock()

	for uuid, path := range paths {
		visited[path] = struct{}{}

		var mtime time.Time
		var size int64
		if info, err := os.Stat(path); err == nil {
			mtime = info.ModTime()
			size = info.Size()
		}
		fp := fingerprint(mtime, size)

		entry := scanCache.copilot[path]
		if entry == nil || entry.fp != fp {
			entry = parseCopilotFile(path, uuid, windowStart)
			if entry == nil {
				delete(scanCache.copilot, path)
				continue
			}
			entry.fp = fp
			scanCache.copilot[path] = entry
		}
		entry.mergeInto(&s, windowKey, sessions)
	}

	sweepToolCache(scanCache.copilot, visited)
	s.Sessions = len(sessions)
	s.Today = s.Daily[DayKey(time.Now())]
	if s.Sessions == 0 {
		s.Note = "세션 로그가 없습니다"
	}
	return s
}

// parseCopilotFile — events 파일 하나를 파싱해 캐시 엔트리를 만든다. 열기 실패 시 nil.
func parseCopilotFile(path, uuid string, windowStart time.Time) *toolFileEntry {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	e := newToolFileEntry()
	e.sessionIDs = append(e.sessionIDs, uuid) // 세션 = 고유 uuid (shutdown 없어도 카운트)

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if !bytes.Contains(line, copilotShutdownToken) {
			continue
		}
		var ev copilotEvent
		if json.Unmarshal(line, &ev) != nil || ev.Type != "session.shutdown" || ev.Data.ModelMetrics == nil {
			continue
		}
		ts := parseGeminiTime(ev.Timestamp)
		for modelKey, metrics := range ev.Data.ModelMetrics {
			u := metrics.Usage
			freshInput := u.InputTokens - u.CacheReadTokens - u.CacheWriteTokens
			if freshInput < 0 {
				freshInput = 0
			}
			total := freshInput + u.OutputTokens + u.CacheReadTokens + u.CacheWriteTokens
			if total == 0 {
				continue
			}
			e.add(TokenUsage{
				Input:      freshInput,
				Output:     u.OutputTokens,
				CacheRead:  u.CacheReadTokens,
				CacheWrite: u.CacheWriteTokens,
				Reasoning:  u.ReasoningTokens,
				Total:      total,
			}, normalizeCopilotModel(modelKey), ts, windowStart)
		}
	}
	return e
}

// normalizeCopilotModel — claude- 계열은 버전 점을 하이픈으로(claude-sonnet-4.6 → claude-sonnet-4-6).
// 그 외 모델(gpt-* 등)은 그대로 둔다 — 요율표가 이미 점을 쓴다.
func normalizeCopilotModel(model string) string {
	if strings.HasPrefix(model, "claude-") {
		return strings.ReplaceAll(model, ".", "-")
	}
	return model
}

// fileExists — 일반 파일이 존재하는지.
func fileExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}
