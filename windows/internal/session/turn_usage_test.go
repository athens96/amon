package session

import (
	"path/filepath"
	"testing"
)

func testClaudeAssistantUsage(
	t *testing.T, text, id, ts string, sidechain bool, usage map[string]any,
) string {
	return jsonLine(t, map[string]any{
		"type": "assistant", "timestamp": ts, "isSidechain": sidechain,
		"requestId": "req-" + id,
		"message": map[string]any{
			"id": id, "model": "claude-opus-4-8",
			"content": []map[string]any{{"type": "text", "text": text}},
			"usage":   usage,
		},
	})
}

func testClaudeToolStep(t *testing.T, id, ts string, usage map[string]any) string {
	return jsonLine(t, map[string]any{
		"type": "assistant", "timestamp": ts, "requestId": "req-" + id,
		"message": map[string]any{
			"id": id, "model": "claude-opus-4-8",
			"content": []map[string]any{{"type": "tool_use", "name": "Bash"}},
			"usage":   usage,
		},
	})
}

func testCodexTokenCount(
	t *testing.T, ts string, input, cached, output, reasoning, total int64,
) string {
	return jsonLine(t, map[string]any{
		"type": "event_msg", "timestamp": ts,
		"payload": map[string]any{
			"type": "token_count",
			"info": map[string]any{"total_token_usage": map[string]any{
				"input_tokens": input, "cached_input_tokens": cached,
				"output_tokens": output, "reasoning_output_tokens": reasoning,
				"total_tokens": total,
			}},
		},
	})
}

func TestClaudeTurnUsageAttributedToRequestPair(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "p", "session-u.jsonl")
	writeFixture(t, file, []string{
		claudeUser(t, "첫 요청", "2026-07-14T01:00:00Z", "typed"),
		testClaudeAssistantUsage(t, "답 1", "msg-1", "2026-07-14T01:00:01Z", false, map[string]any{
			"input_tokens": 50, "output_tokens": 5, "cache_read_input_tokens": 100,
		}),
		// 같은 키의 스트리밍 재등장은 last-wins.
		testClaudeAssistantUsage(t, "답 1", "msg-1", "2026-07-14T01:00:02Z", false, map[string]any{
			"input_tokens": 100, "output_tokens": 10,
			"cache_read_input_tokens": 200, "cache_creation_input_tokens": 30,
		}),
		testClaudeToolStep(t, "msg-2", "2026-07-14T01:00:03Z", map[string]any{
			"input_tokens": 7, "output_tokens": 3,
		}),
		claudeUser(t, "둘째 요청", "2026-07-14T01:01:00Z", "typed"),
		testClaudeAssistantUsage(t, "답 2", "msg-4", "2026-07-14T01:01:01Z", false, map[string]any{
			"input_tokens": 20, "output_tokens": 2,
		}),
	})

	turns, err := LoadTranscript(record("claude", "session-u", file), dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(turns) != 4 || turns[0].Usage == nil || turns[2].Usage == nil {
		t.Fatalf("turn usage missing: %+v", turns)
	}
	want := TurnUsage{Input: 107, Output: 13, CacheRead: 200, CacheWrite: 30, Total: 350}
	if *turns[0].Usage != want {
		t.Fatalf("first pair usage = %+v, want %+v", *turns[0].Usage, want)
	}
	if turns[1].Usage != nil || turns[3].Usage != nil {
		t.Fatal("assistant turn has usage badge")
	}
}

func TestCodexTurnUsageFromCumulativeSnapshots(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "2026", "rollout-2026-07-14T02-00-00-session-y.jsonl")
	writeFixture(t, file, []string{
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:00:00Z",
			"payload": map[string]any{"type": "user_message", "message": "첫 요청"},
		}),
		testCodexTokenCount(t, "2026-07-14T02:00:06Z", 1000, 400, 50, 10, 1050),
		jsonLine(t, map[string]any{
			"type": "event_msg", "timestamp": "2026-07-14T02:01:00Z",
			"payload": map[string]any{"type": "user_message", "message": "둘째 요청"},
		}),
		testCodexTokenCount(t, "2026-07-14T02:01:06Z", 2000, 900, 120, 25, 2120),
	})

	turns, err := LoadTranscript(record("codex", "session-y", file), "", dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(turns) != 2 || turns[0].Usage == nil || turns[1].Usage == nil {
		t.Fatalf("turn usage missing: %+v", turns)
	}
	if got, want := *turns[0].Usage, (TurnUsage{Input: 600, Output: 50, CacheRead: 400, Reasoning: 10, Total: 1050}); got != want {
		t.Fatalf("first pair usage = %+v, want %+v", got, want)
	}
	if got, want := *turns[1].Usage, (TurnUsage{Input: 500, Output: 70, CacheRead: 500, Reasoning: 15, Total: 1070}); got != want {
		t.Fatalf("second pair usage = %+v, want %+v", got, want)
	}
}
