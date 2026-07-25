package session

// 맥 SessionTranscriptTests 포팅 — 목록의 첫 줄 요약과 달리 상세는 **본문 전체**를
// 복원해야 한다. 스캐너·전문 로더가 같은 파싱 규칙을 쓰는지도 여기서 지킨다.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeFixture(t *testing.T, path string, lines []string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "")), 0o644); err != nil {
		t.Fatal(err)
	}
	// 방금 수정된 로그는 진행 중일 수 있어 스캐너가 건너뛴다(ActiveGrace).
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
}

func jsonLine(t *testing.T, obj map[string]any) string {
	t.Helper()
	data, err := json.Marshal(obj)
	if err != nil {
		t.Fatal(err)
	}
	return string(data) + "\n"
}

func claudeUser(t *testing.T, text, ts, promptSource string) string {
	return jsonLine(t, map[string]any{
		"type": "user", "timestamp": ts, "promptSource": promptSource,
		"cwd": "/tmp/project", "gitBranch": "main",
		"message": map[string]any{
			"content": []map[string]any{{"type": "text", "text": text}},
		},
	})
}

func claudeAssistant(t *testing.T, text, id, ts string, sidechain bool, tokens int64) string {
	message := map[string]any{
		"id": id, "model": "claude-opus-4-8",
		"content": []map[string]any{{"type": "text", "text": text}},
	}
	if tokens > 0 {
		message["usage"] = map[string]any{"input_tokens": tokens, "output_tokens": tokens}
	}
	return jsonLine(t, map[string]any{
		"type": "assistant", "timestamp": ts, "isSidechain": sidechain,
		"requestId": "req-" + id, "message": message,
	})
}

func record(provider, sessionID, sourcePath string) Record {
	return Record{Provider: provider, SessionID: sessionID, SourcePath: sourcePath}
}

// --- Claude 전문 ---

func TestClaudeTranscriptKeepsFullPromptAndAnswerInOrder(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "p", "session-a.jsonl")
	longAnswer := "첫 줄 요약\n둘째 줄 상세\n셋째 줄 결론"
	writeFixture(t, file, []string{
		claudeUser(t, "배포 스크립트를 고쳐줘\n두 번째 줄도 프롬프트다", "2026-07-14T01:00:00Z", "typed"),
		claudeAssistant(t, longAnswer, "msg-1", "2026-07-14T01:00:05Z", false, 0),
	})

	turns, err := LoadTranscript(record("claude", "session-a", file), dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(turns) != 2 || turns[0].Role != "user" || turns[1].Role != "assistant" {
		t.Fatalf("턴 구성이 어긋남: %+v", turns)
	}
	if turns[0].Text != "배포 스크립트를 고쳐줘\n두 번째 줄도 프롬프트다" {
		t.Errorf("요청 전문이 잘림: %q", turns[0].Text)
	}
	if turns[1].Text != longAnswer {
		t.Errorf("응답 전문이 잘림: %q", turns[1].Text)
	}
	if turns[1].Timestamp.IsZero() {
		t.Error("타임스탬프 누락")
	}
}

func TestClaudeSplitAssistantBlocksMergeIntoOneTurn(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "p", "session-b.jsonl")
	writeFixture(t, file, []string{
		claudeUser(t, "질문", "2026-07-14T01:00:00Z", "typed"),
		claudeAssistant(t, "앞부분", "msg-1", "2026-07-14T01:00:01Z", false, 0),
		claudeAssistant(t, "뒷부분", "msg-1", "2026-07-14T01:00:02Z", false, 0),
	})

	turns, err := LoadTranscript(record("claude", "session-b", file), dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(turns) != 2 || turns[1].Text != "앞부분\n\n뒷부분" {
		t.Fatalf("블록 병합 실패: %+v", turns)
	}
}

func TestClaudeRepeatedAssistantContentIsNotDuplicated(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "p", "session-c.jsonl")
	writeFixture(t, file, []string{
		claudeUser(t, "질문", "2026-07-14T01:00:00Z", "typed"),
		claudeAssistant(t, "같은 답", "msg-1", "2026-07-14T01:00:01Z", false, 0),
		claudeAssistant(t, "같은 답", "msg-1", "2026-07-14T01:00:02Z", false, 0),
	})

	turns, err := LoadTranscript(record("claude", "session-c", file), dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(turns) != 2 || turns[1].Text != "같은 답" {
		t.Fatalf("반복 본문이 중복 병합됨: %+v", turns)
	}
}

func TestClaudeExcludesSidechainAndInjectedPrompts(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "p", "session-d.jsonl")
	writeFixture(t, file, []string{
		claudeUser(t, "진짜 요청", "2026-07-14T01:00:00Z", "typed"),
		claudeUser(t, "훅이 넣은 것", "2026-07-14T01:00:01Z", "system"),
		claudeUser(t, "<system-reminder>주입</system-reminder>", "2026-07-14T01:00:02Z", "typed"),
		claudeAssistant(t, "서브에이전트 응답", "msg-9", "2026-07-14T01:00:03Z", true, 0),
		claudeAssistant(t, "본 세션 응답", "msg-1", "2026-07-14T01:00:04Z", false, 0),
	})

	turns, err := LoadTranscript(record("claude", "session-d", file), dir, "")
	if err != nil {
		t.Fatal(err)
	}
	var texts []string
	for _, turn := range turns {
		texts = append(texts, turn.Text)
	}
	want := []string{"진짜 요청", "본 세션 응답"}
	if len(texts) != len(want) || texts[0] != want[0] || texts[1] != want[1] {
		t.Fatalf("제외 규칙이 어긋남: %v", texts)
	}
}

// --- Codex 전문 ---

func codexFixtureLines(t *testing.T) []string {
	return []string{
		jsonLine(t, map[string]any{
			"type": "session_meta", "timestamp": "2026-07-14T02:00:00Z",
			"payload": map[string]any{"id": "session-x", "cwd": "/tmp/proj"},
		}),
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:00:01Z",
			"payload": map[string]any{"type": "user_message", "message": "리팩터링 해줘"},
		}),
		jsonLine(t, map[string]any{
			"type": "response_item", "timestamp": "2026-07-14T02:00:01Z",
			"payload": map[string]any{
				"type": "message", "role": "user",
				"content": []map[string]any{{"type": "input_text", "text": "리팩터링 해줘"}},
			},
		}),
		jsonLine(t, map[string]any{
			"type": "response_item", "timestamp": "2026-07-14T02:00:10Z",
			"payload": map[string]any{
				"type": "message", "role": "assistant",
				"content": []map[string]any{{"type": "output_text", "text": "전체 응답\n두 번째 줄"}},
			},
		}),
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:00:11Z",
			"payload": map[string]any{
				"type": "token_count",
				"info": map[string]any{"total_token_usage": map[string]any{
					"input_tokens": 100, "cached_input_tokens": 40,
					"output_tokens": 20, "total_tokens": 120,
				}},
			},
		}),
	}
}

func TestCodexTranscriptDedupesUserMessageRecordedTwice(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "2026", "rollout-2026-07-14T02-00-00-session-x.jsonl")
	writeFixture(t, file, codexFixtureLines(t))

	turns, err := LoadTranscript(record("codex", "session-x", file), "", dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(turns) != 2 {
		t.Fatalf("이중 기록 dedup 실패: %+v", turns)
	}
	if turns[0].Text != "리팩터링 해줘" || turns[1].Text != "전체 응답\n두 번째 줄" {
		t.Fatalf("전문이 어긋남: %+v", turns)
	}
}

// --- 스캐너 ---

func TestScanClaudeBuildsRecordWithSourcePath(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "proj", "session-e.jsonl")
	writeFixture(t, file, []string{
		claudeUser(t, "요청 첫 줄\n둘째 줄", "2026-07-14T01:00:00Z", "typed"),
		claudeAssistant(t, "응답", "msg-1", "2026-07-14T01:00:01Z", false, 12),
		claudeAssistant(t, "응답", "msg-1", "2026-07-14T01:00:02Z", false, 12), // 같은 키 반복 — last-wins
	})

	records := ScanClaude(dir, LoadFileCache(""))
	if len(records) != 1 {
		t.Fatalf("기록 수 = %d", len(records))
	}
	rec := records[0]
	if rec.SourcePath != file {
		t.Errorf("sourcePath = %q", rec.SourcePath)
	}
	if rec.TotalTokens != 24 { // 12+12 한 번만 (dedup)
		t.Errorf("토큰 dedup 실패: %d", rec.TotalTokens)
	}
	if len(rec.Prompts) != 1 || rec.Prompts[0] != "요청 첫 줄" {
		t.Errorf("요약은 첫 줄만: %v", rec.Prompts)
	}
	if rec.GitBranch != "main" || rec.ProjectLabel != "project" {
		t.Errorf("메타 누락: %+v", rec)
	}
}

func TestScanCodexBuildsRecord(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "2026", "rollout-2026-07-14T02-00-00-session-x.jsonl")
	writeFixture(t, file, codexFixtureLines(t))

	records := ScanCodex(dir, LoadFileCache(""))
	if len(records) != 1 {
		t.Fatalf("기록 수 = %d", len(records))
	}
	rec := records[0]
	if rec.SessionID != "session-x" || rec.SourcePath != file {
		t.Errorf("식별 정보: %+v", rec)
	}
	// cached 는 input 의 부분집합 — 분리 저장.
	if rec.InputTokens != 60 || rec.CacheTokens != 40 || rec.OutputTokens != 20 || rec.TotalTokens != 120 {
		t.Errorf("토큰 분해: %+v", rec)
	}
	if rec.PromptCount != 1 { // event_msg 와 response_item 이중 기록 dedup
		t.Errorf("promptCount = %d", rec.PromptCount)
	}
}

func TestScanCodexIncludesRecentlyModifiedSession(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "2026", "rollout-recent.jsonl")
	writeFixture(t, file, codexFixtureLines(t))
	if err := os.Chtimes(file, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}

	records := ScanCodex(dir, LoadFileCache(""))
	if len(records) != 1 {
		t.Fatalf("최근 세션 수 = %d, want 1", len(records))
	}
}

func TestScanCodexLifecycleOverridesRecentMtimeAndAllowsPreTokenTurn(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "2026", "rollout-live.jsonl")
	writeFixture(t, file, []string{
		jsonLine(t, map[string]any{
			"type": "session_meta", "timestamp": "2026-07-14T02:00:00Z",
			"payload": map[string]any{"id": "session-live", "cwd": "/tmp/live-project"},
		}),
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:00:01Z",
			"payload": map[string]any{"type": "user_message", "message": "작업 시작"},
		}),
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:00:02Z",
			"payload": map[string]any{"type": "task_started"},
		}),
	})
	if err := os.Chtimes(file, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}

	records := ScanCodex(dir, LoadFileCache(""))
	if len(records) != 1 {
		t.Fatalf("records = %d, want 1 pre-token active turn", len(records))
	}
	if records[0].Status != "active" || records[0].CurrentTask != "작업 시작" {
		t.Fatalf("live record = %+v", records[0])
	}

	withComplete := append([]string{}, codexFixtureLines(t)...)
	withComplete = append(withComplete, jsonLine(t, map[string]any{
		"type": "event_msg", "timestamp": "2026-07-14T02:00:12Z",
		"payload": map[string]any{"type": "task_complete"},
	}))
	writeFixture(t, file, withComplete)
	if err := os.Chtimes(file, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}
	records = ScanCodex(dir, LoadFileCache(""))
	if len(records) != 1 || records[0].Status != "idle" {
		t.Fatalf("completed recent rollout must be idle: %+v", records)
	}
}

func TestScanCodexUsesCurrentAgentPreviewWithoutStaleTurnOutput(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "2026", "rollout-live-output.jsonl")
	lines := append([]string{}, codexFixtureLines(t)...)
	lines = append(lines,
		jsonLine(t, map[string]any{
			"type": "response_item", "timestamp": "2026-07-14T02:00:12Z",
			"payload": map[string]any{
				"type": "message", "role": "user",
				"content": []map[string]any{
					{"type": "input_text", "text": "두 번째 작업"},
				},
			},
		}),
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:00:13Z",
			"payload": map[string]any{"type": "task_started"},
		}),
	)
	writeFixture(t, file, lines)
	record := parseCodexRollout(file)
	if record == nil {
		t.Fatal("active rollout was not parsed")
	}
	if record.CurrentTask != "두 번째 작업" || record.LastResult != "" {
		t.Fatalf("new turn retained stale output: %+v", record)
	}

	lines = append(lines,
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:00:14Z",
			"payload": map[string]any{
				"type": "agent_message", "message": "새 응답 생성 중\n두 번째 줄",
			},
		}),
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:00:15Z",
			"payload": map[string]any{
				"type": "agent_message", "message": `{"kind":"internal"}`,
			},
		}),
	)
	writeFixture(t, file, lines)
	record = parseCodexRollout(file)
	if record == nil || record.LastResult != "새 응답 생성 중" {
		t.Fatalf("agent preview = %+v, want current plain-text output", record)
	}
}

// --- 원본 경로 해석 ---

func TestLocatesClaudeSourceBySessionIDWhenPathMissing(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "proj", "session-f.jsonl")
	writeFixture(t, file, []string{
		claudeUser(t, "요청", "2026-07-14T01:00:00Z", "typed"),
		claudeAssistant(t, "응답 전문", "msg-1", "2026-07-14T01:00:01Z", false, 0),
	})

	turns, err := LoadTranscript(record("claude", "session-f", ""), dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(turns) != 2 || turns[1].Text != "응답 전문" {
		t.Fatalf("id 폴백 탐색 실패: %+v", turns)
	}
}

func TestMissingSourceReturnsError(t *testing.T) {
	_, err := LoadTranscript(record("claude", "없는세션", "/nope/none.jsonl"), t.TempDir(), "")
	if err != ErrSourceNotFound {
		t.Fatalf("err = %v", err)
	}
}

// --- 저장소 ---

func TestStoreUpsertLastWinsAndSorted(t *testing.T) {
	st := &Store{Path: filepath.Join(t.TempDir(), "sessions.jsonl")}
	older := Record{Provider: "claude", SessionID: "a", EndedAt: time.Now().Add(-time.Hour), TotalTokens: 1}
	newer := Record{Provider: "claude", SessionID: "b", EndedAt: time.Now(), TotalTokens: 2}
	st.Upsert([]Record{older, newer})

	updated := older
	updated.TotalTokens = 99
	merged := st.Upsert([]Record{updated})

	if len(merged) != 2 || merged[0].SessionID != "b" {
		t.Fatalf("정렬이 어긋남: %+v", merged)
	}
	if merged[1].TotalTokens != 99 {
		t.Fatalf("재적재가 갱신되지 않음: %+v", merged[1])
	}
}
