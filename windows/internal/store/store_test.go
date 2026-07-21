package store

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	_ "modernc.org/sqlite"

	"github.com/athens96/amon/windows/internal/scan"
	"github.com/athens96/amon/windows/internal/session"
)

func openRO(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func sampleSummaries(day string) []scan.ToolSummary {
	claude := scan.ToolSummary{
		Tool: "claudeCode", DisplayName: "Claude Code",
		Usage:        scan.TokenUsage{Input: 100, Output: 50, CacheRead: 200, CacheWrite: 10, Reasoning: 5, Total: 360},
		Daily:        map[string]scan.TokenUsage{day: {Input: 100, Output: 50, CacheRead: 200, CacheWrite: 10, Total: 360}},
		Models:       map[string]int64{"claude-opus-4-8": 360},
		Sessions:     3,
		LastActivity: time.Now(),
		PathExists:   true,
	}
	claude.DailyByModel = map[string]map[string]scan.TokenUsage{
		day: {"claude-opus-4-8": {Input: 100, Output: 50, CacheRead: 200, CacheWrite: 10, Reasoning: 5, Total: 360}},
	}
	cursor := scan.ToolSummary{
		Tool: "cursor", DisplayName: "Cursor",
		Usage:        scan.TokenUsage{Input: 1000, Output: 200, Total: 1200},
		Models:       map[string]int64{"auto": 1200},
		CostUSD:      1.23,
		Sessions:     2,
		LastActivity: time.Now(),
		PathExists:   true,
		DailyByModel: map[string]map[string]scan.TokenUsage{
			day: {"auto": {Input: 1000, Output: 200, Total: 1200}},
		},
		DailyCostByModel: map[string]map[string]float64{day: {"auto": 1.23}},
	}
	return []scan.ToolSummary{claude, cursor}
}

func TestStoreSaveAndQuery(t *testing.T) {
	path := filepath.Join(t.TempDir(), "usage.db")
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	day := scan.DayKey(time.Now())
	rec := session.Record{
		Provider: "claude", SessionID: "s1", ProjectLabel: "proj", GitBranch: "main",
		StartedAt: time.Now().Add(-time.Hour), EndedAt: time.Now(),
		Prompts: []string{"first prompt", "second"}, PromptCount: 2,
		InputTokens: 100, OutputTokens: 50, CacheTokens: 210, TotalTokens: 360,
		Models: map[string]int64{"claude-opus-4-8": 360}, AgentCount: 1,
	}
	if err := st.Save(sampleSummaries(day), []session.Record{rec}, Meta{Machine: "box", AppVersion: "9.9.9"}); err != nil {
		t.Fatal(err)
	}

	db := openRO(t, path)

	// usage_daily: claudeCode 비용 NULL, cursor 비용 1.23
	var model string
	var total int64
	var cost sql.NullFloat64
	if err := db.QueryRow(
		`SELECT model,total,cost_usd FROM usage_daily WHERE date=? AND tool='claudeCode'`, day,
	).Scan(&model, &total, &cost); err != nil {
		t.Fatal(err)
	}
	if model != "claude-opus-4-8" || total != 360 || cost.Valid {
		t.Fatalf("claude usage_daily: model=%s total=%d costValid=%v", model, total, cost.Valid)
	}
	if err := db.QueryRow(
		`SELECT cost_usd FROM usage_daily WHERE date=? AND tool='cursor'`, day,
	).Scan(&cost); err != nil {
		t.Fatal(err)
	}
	if !cost.Valid || cost.Float64 != 1.23 {
		t.Fatalf("cursor cost = %+v, want 1.23", cost)
	}

	// tool_totals
	var ttTotal, ttSessions int64
	var modelsJSON string
	if err := db.QueryRow(
		`SELECT total,sessions,models_json FROM tool_totals WHERE tool='claudeCode'`,
	).Scan(&ttTotal, &ttSessions, &modelsJSON); err != nil {
		t.Fatal(err)
	}
	if ttTotal != 360 || ttSessions != 3 || modelsJSON != `{"claude-opus-4-8":360}` {
		t.Fatalf("tool_totals: total=%d sessions=%d models=%s", ttTotal, ttSessions, modelsJSON)
	}

	// sessions: provider→tool 매핑, cache_read=CacheTokens, first_prompt
	var sTool, firstPrompt, sModels string
	var sCacheRead, sTotal int64
	var sCost sql.NullFloat64
	if err := db.QueryRow(
		`SELECT tool,cache_read,total,first_prompt,models_json,cost_usd FROM sessions WHERE id='claude:s1'`,
	).Scan(&sTool, &sCacheRead, &sTotal, &firstPrompt, &sModels, &sCost); err != nil {
		t.Fatal(err)
	}
	if sTool != "claudeCode" || sCacheRead != 210 || sTotal != 360 ||
		firstPrompt != "first prompt" || sModels != `["claude-opus-4-8"]` || sCost.Valid {
		t.Fatalf("sessions row: tool=%s cache_read=%d total=%d first=%s models=%s costValid=%v",
			sTool, sCacheRead, sTotal, firstPrompt, sModels, sCost.Valid)
	}

	// meta
	var machine, version string
	_ = db.QueryRow(`SELECT value FROM meta WHERE key='machine'`).Scan(&machine)
	_ = db.QueryRow(`SELECT value FROM meta WHERE key='app_version'`).Scan(&version)
	if machine != "box" || version != "9.9.9" {
		t.Fatalf("meta: machine=%s version=%s", machine, version)
	}
}

func TestStoreWindowPreservesOldRows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "usage.db")
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	day := scan.DayKey(time.Now())
	// 첫 저장 — 오늘 데이터.
	if err := st.Save(sampleSummaries(day), nil, Meta{Machine: "box", AppVersion: "1"}); err != nil {
		t.Fatal(err)
	}

	// 창 밖(40일 전) 행을 직접 삽입 — 과거 스캔의 역사 시뮬레이션.
	oldDay := scan.DayKey(time.Now().AddDate(0, 0, -40))
	{
		rw, err := sql.Open("sqlite", "file:"+path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := rw.Exec(
			`INSERT INTO usage_daily(date,tool,model,total) VALUES(?,?,?,?)`,
			oldDay, "claudeCode", "claude-opus-4-8", 999); err != nil {
			t.Fatal(err)
		}
		rw.Close()
	}

	// 두 번째 저장 — 오늘 값이 바뀌어도 창 밖 40일 전 행은 보존돼야 한다.
	sums := sampleSummaries(day)
	sums[0].DailyByModel[day]["claude-opus-4-8"] = scan.TokenUsage{Total: 111, Input: 111}
	if err := st.Save(sums, nil, Meta{Machine: "box", AppVersion: "1"}); err != nil {
		t.Fatal(err)
	}

	db := openRO(t, path)
	var oldTotal int64
	if err := db.QueryRow(
		`SELECT total FROM usage_daily WHERE date=? AND tool='claudeCode'`, oldDay,
	).Scan(&oldTotal); err != nil {
		t.Fatalf("old row missing: %v", err)
	}
	if oldTotal != 999 {
		t.Fatalf("old row total = %d, want 999 (preserved)", oldTotal)
	}
	var newTotal int64
	if err := db.QueryRow(
		`SELECT total FROM usage_daily WHERE date=? AND tool='claudeCode'`, day,
	).Scan(&newTotal); err != nil {
		t.Fatal(err)
	}
	if newTotal != 111 {
		t.Fatalf("window row total = %d, want 111 (replaced)", newTotal)
	}
}

func TestStoreVacuumInto(t *testing.T) {
	path := filepath.Join(t.TempDir(), "usage.db")
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	day := scan.DayKey(time.Now())
	if err := st.Save(sampleSummaries(day), nil, Meta{Machine: "box", AppVersion: "1"}); err != nil {
		t.Fatal(err)
	}

	dst := filepath.Join(t.TempDir(), "snap.db")
	if err := st.VacuumInto(dst); err != nil {
		t.Fatal(err)
	}
	// SQLite 매직바이트 확인 (백엔드 ingest 검증과 동일 조건).
	data, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) < 16 || string(data[:16]) != "SQLite format 3\x00" {
		t.Fatalf("vacuumed file is not a SQLite db")
	}
	// 두 번째 VacuumInto 는 기존 파일을 덮어써야 한다(대상 존재 시 실패하지 않음).
	if err := st.VacuumInto(dst); err != nil {
		t.Fatalf("second VacuumInto: %v", err)
	}
}
