package pet

import (
	"strings"
	"testing"
	"time"

	"github.com/athens96/amon/windows/internal/session"
)

func TestPresentationsSelectsHighestAttentionState(t *testing.T) {
	now := time.Unix(100, 0)
	explicit := live("explicit", "", time.Unix(5, 0), now)
	explicit.State.Status = StatusBlocked
	records := []LiveRecord{
		live("running", "active", time.Unix(40, 0), now),
		explicit,
		live("input", "awaiting_approval", time.Unix(10, 0), now),
	}

	got := Presentations(records, now)
	if len(got) != 1 {
		t.Fatalf("len(Presentations) = %d, want 1", len(got))
	}
	if got[0].Status != StatusNeedsInput || got[0].SessionID != "input" {
		t.Fatalf("presentation = %#v, want needs-input session", got[0])
	}
	if got[0].ActiveCount != 1 {
		t.Errorf("ActiveCount = %d, want 1", got[0].ActiveCount)
	}
}

func TestPresentationsRunningCarouselIsStableAndComplete(t *testing.T) {
	now := time.Unix(100, 0)
	first := live("first", "active", time.Unix(20, 0), now)
	first.Record.CurrentTask = "첫 번째 입력"
	first.Record.LastResult = "첫 번째 출력"
	first.Record.InputTokens = 1200
	first.Record.OutputTokens = 340
	first.Record.TotalTokens = 1540
	second := live("second", "running", time.Unix(10, 0), now)
	history := live("history", "idle", time.Unix(30, 0), now)
	history.Record.LastResult = "완료 출력"

	got := Presentations([]LiveRecord{second, history, first}, now)
	if len(got) != 2 {
		t.Fatalf("len(Presentations) = %d, want 2", len(got))
	}
	if got[0].SessionID != "first" || got[1].SessionID != "second" {
		t.Errorf("session order = [%q, %q], want [first, second]", got[0].SessionID, got[1].SessionID)
	}
	if got[0].Detail != "첫 번째 입력" || got[0].Output != "첫 번째 출력" {
		t.Errorf("input/output = %q/%q", got[0].Detail, got[0].Output)
	}
	if got[0].InputTokens != 1200 || got[0].OutputTokens != 340 || got[0].TotalTokens != 1540 {
		t.Errorf("tokens = %d/%d/%d", got[0].InputTokens, got[0].OutputTokens, got[0].TotalTokens)
	}
	for _, presentation := range got {
		if presentation.Status != StatusRunning || presentation.ActiveCount != 2 {
			t.Errorf("carousel presentation = %#v", presentation)
		}
	}
}

func TestPresentationsUsesSourceMTimeOnlyWithoutLifecycle(t *testing.T) {
	now := time.Unix(1_000, 0)
	fallbackActive := LiveRecord{
		Record: session.Record{Provider: "codex", SessionID: "mtime"},
		State:  RecordState{ModifiedAt: now.Add(-SourceActiveInterval)},
	}
	explicitIdle := LiveRecord{
		Record: session.Record{Provider: "codex", SessionID: "idle"},
		State: RecordState{
			Lifecycle:  "idle",
			ModifiedAt: now,
		},
	}
	old := LiveRecord{
		Record: session.Record{Provider: "codex", SessionID: "old"},
		State:  RecordState{ModifiedAt: now.Add(-SourceActiveInterval - time.Nanosecond)},
	}

	got := Presentations([]LiveRecord{explicitIdle, old, fallbackActive}, now)
	if len(got) != 1 || got[0].SessionID != "mtime" || got[0].Status != StatusRunning {
		t.Fatalf("Presentations = %#v, want only mtime fallback active", got)
	}
}

func TestPresentationsShowsOnlyLatestCompletedResult(t *testing.T) {
	now := time.Unix(100, 0)
	old := live("old", "idle", time.Unix(10, 0), time.Unix(10, 0))
	old.Record.LastResult = "old output"
	newest := live("newest", "completed", time.Unix(5, 0), time.Unix(30, 0))
	newest.Record.LastResult = "new output"
	noOutput := live("no-output", "idle", time.Unix(40, 0), time.Unix(40, 0))

	got := Presentations([]LiveRecord{old, noOutput, newest}, now)
	if len(got) != 1 {
		t.Fatalf("len(Presentations) = %d, want 1", len(got))
	}
	if got[0].SessionID != "newest" || got[0].Status != StatusReady || got[0].ActiveCount != 0 {
		t.Errorf("presentation = %#v, want latest ready result", got[0])
	}
}

func TestPresentationsBoundsSingleLineDisplayText(t *testing.T) {
	now := time.Unix(100, 0)
	record := live("bounded", "active", time.Unix(1, 0), now)
	record.Record.ProjectLabel = strings.Repeat("가", 90)
	record.Record.CurrentTask = strings.Repeat("나", 130) + "\nsecond line"
	record.Record.LastResult = strings.Repeat("다", 170) + "\nsecond line"

	got := PresentationFor([]LiveRecord{record}, now)
	if len([]rune(got.Title)) != 80 {
		t.Errorf("title rune count = %d, want 80", len([]rune(got.Title)))
	}
	if len([]rune(got.Detail)) != 120 || strings.ContainsAny(got.Detail, "\r\n") {
		t.Errorf("detail is not a bounded single line: %q", got.Detail)
	}
	if len([]rune(got.Output)) != 160 || strings.ContainsAny(got.Output, "\r\n") {
		t.Errorf("output is not a bounded single line: %q", got.Output)
	}
}

func TestStatusFromStringMapsKnownValuesConservatively(t *testing.T) {
	tests := map[string]Status{
		"active":               StatusRunning,
		"needsInput":           StatusNeedsInput,
		"Needs Input":          StatusNeedsInput,
		"awaiting-approval":    StatusNeedsInput,
		"failure":              StatusBlocked,
		"completed":            StatusReady,
		"waiting":              StatusIdle,
		"unexpected-new-state": StatusIdle,
	}
	for raw, want := range tests {
		if got := StatusFromString(raw); got != want {
			t.Errorf("StatusFromString(%q) = %q, want %q", raw, got, want)
		}
	}
}

func TestPresentationForEmptyReturnsIdle(t *testing.T) {
	got := PresentationFor(nil, time.Now())
	if got != Idle() {
		t.Errorf("PresentationFor(nil) = %#v, want %#v", got, Idle())
	}
}

func TestCarouselWrapsAndPreservesIdentity(t *testing.T) {
	presentations := []Presentation{
		{SessionIdentity: "codex:first"},
		{SessionIdentity: "codex:second"},
	}

	if got := MovedIdentity("codex:first", -1, presentations); got != "codex:second" {
		t.Errorf("move left = %q, want codex:second", got)
	}
	if got := MovedIdentity("codex:second", 1, presentations); got != "codex:first" {
		t.Errorf("move right = %q, want codex:first", got)
	}
	if got := MovedIdentity("codex:first", 5, presentations); got != "codex:second" {
		t.Errorf("large move = %q, want codex:second", got)
	}
	if got := PreservedIdentity("codex:second", 0, presentations); got != "codex:second" {
		t.Errorf("preserved identity = %q, want codex:second", got)
	}
	if got := PreservedIdentity("missing", 9, presentations); got != "codex:second" {
		t.Errorf("clamped identity = %q, want codex:second", got)
	}
	if got := PreservedIdentity("", -2, presentations); got != "codex:first" {
		t.Errorf("negative index identity = %q, want codex:first", got)
	}
	if got := MovedIdentity("", 1, nil); got != "" {
		t.Errorf("empty carousel identity = %q, want empty", got)
	}
}

func live(id, lifecycle string, startedAt, updatedAt time.Time) LiveRecord {
	return LiveRecord{
		Record: session.Record{
			Provider:     "codex",
			SessionID:    id,
			ProjectLabel: "amon-dev",
			StartedAt:    startedAt,
		},
		State: RecordState{
			Lifecycle: lifecycle,
			UpdatedAt: updatedAt,
		},
	}
}
