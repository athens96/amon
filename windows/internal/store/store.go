// Package store — 로컬 사용량 SQLite(usage.db)의 저장 계층.
//
// A-mon 스캐너 결과(도구별 요약 + 세션 기록)를 %APPDATA%\A-mon\usage.db 에 적재한다.
// 스키마·갱신 규칙은 에이전트 대시보드 SPEC §1 을 따르며, mac 앱과 동일 스키마다:
//   - usage_daily : 스캔 창(30일) 내 일자×도구×모델별 토큰(+소스 비용). 창 이전은 보존.
//   - tool_totals : 도구별 전체 누적 스냅샷 + UI 렌더 상태.
//   - sessions    : 종료 세션 기록 미러(최대 2000행).
//
// A-mon UI는 여기서 읽고, 서버에는 meta+usage_daily 전용 새 스냅샷만 올린다.
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"time"

	_ "modernc.org/sqlite" // 순수 Go SQLite 드라이버 (cgo 불필요)

	"github.com/athens96/amon/windows/internal/scan"
	"github.com/athens96/amon/windows/internal/session"
)

// maxSessions — sessions 테이블 상한. 초과 시 오래된 ended_at 부터 삭제.
const maxSessions = 2000

// schema — 최초 오픈 시 적용. SPEC §1 과 1:1.
const schema = `
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS usage_daily(
  date TEXT NOT NULL,
  tool TEXT NOT NULL,
  model TEXT NOT NULL DEFAULT '',
  input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
  cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
  reasoning INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL,
  PRIMARY KEY(date, tool, model));
CREATE TABLE IF NOT EXISTS tool_totals(
  tool TEXT PRIMARY KEY,
  input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
  cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
  reasoning INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL, sessions INTEGER NOT NULL DEFAULT 0,
  last_activity TEXT,
  models_json TEXT NOT NULL DEFAULT '{}',
  path_exists INTEGER NOT NULL DEFAULT 0, note TEXT);
CREATE TABLE IF NOT EXISTS sessions(
  id TEXT PRIMARY KEY,
  tool TEXT NOT NULL, session_id TEXT NOT NULL,
  project TEXT, git_branch TEXT, started_at TEXT, ended_at TEXT,
  input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
  cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL DEFAULT 0, cost_usd REAL,
  models_json TEXT NOT NULL DEFAULT '[]',
  prompt_count INTEGER NOT NULL DEFAULT 0, first_prompt TEXT,
  agent_count INTEGER NOT NULL DEFAULT 0);
`

// Store — usage.db 핸들.
type Store struct {
	db   *sql.DB
	path string
}

// Meta — meta 테이블에 기록할 스캔 메타데이터.
type Meta struct {
	Machine    string
	AppVersion string
	// DeviceID — 설치 단위 안정 ID(config.Load 가 생성). 서버가 유저의 여러
	// 기기를 구분하는 키. 비어 있으면 서버는 machine 으로 폴백한다.
	DeviceID string
}

// Open — usage.db 를 열고(없으면 생성) 스키마·PRAGMA 를 적용한다.
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // WAL 쓰기 직렬화 (트레이 루프는 어차피 단일 고루틴)
	for _, pragma := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA user_version=1",
	} {
		if _, err := db.Exec(pragma); err != nil {
			db.Close()
			return nil, fmt.Errorf("%s: %w", pragma, err)
		}
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	return &Store{db: db, path: path}, nil
}

// Path — 이 스토어의 파일 경로.
func (s *Store) Path() string { return s.path }

// Close — 핸들 종료.
func (s *Store) Close() error { return s.db.Close() }

// Save — 스캔 요약 + 세션 기록을 한 트랜잭션으로 적재한다.
func (s *Store) Save(summaries []scan.ToolSummary, sessions []session.Record, meta Meta) error {
	now := time.Now()
	windowKey := scan.DayKey(scan.WindowStart(now))

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // 커밋 성공 시 no-op

	if err := writeMeta(tx, meta, now); err != nil {
		return err
	}
	for _, sum := range summaries {
		if err := writeUsageDaily(tx, sum, windowKey); err != nil {
			return err
		}
		if err := writeToolTotals(tx, sum); err != nil {
			return err
		}
	}
	if err := writeSessions(tx, sessions); err != nil {
		return err
	}
	return tx.Commit()
}

func writeMeta(tx *sql.Tx, meta Meta, now time.Time) error {
	rows := [][2]string{
		{"schema_version", "1"},
		{"generated_at", now.UTC().Format(time.RFC3339)},
		{"machine", meta.Machine},
		{"app_version", meta.AppVersion},
		{"device_id", meta.DeviceID},
	}
	for _, kv := range rows {
		if _, err := tx.Exec(
			`INSERT INTO meta(key,value) VALUES(?,?)
			 ON CONFLICT(key) DO UPDATE SET value=excluded.value`, kv[0], kv[1]); err != nil {
			return err
		}
	}
	return nil
}

// writeUsageDaily — 도구별로 창 내 행을 지우고 새 버킷을 넣는다. 창 이전 행은 보존.
func writeUsageDaily(tx *sql.Tx, sum scan.ToolSummary, windowKey string) error {
	if _, err := tx.Exec(
		`DELETE FROM usage_daily WHERE tool=? AND date>=?`, sum.Tool, windowKey); err != nil {
		return err
	}
	for date, byModel := range sum.DailyByModel {
		if date < windowKey {
			continue
		}
		for model, u := range byModel {
			var cost any // NULL 기본 — 소스가 준 비용이 있을 때만 값
			if row, ok := sum.DailyCostByModel[date]; ok {
				if c, ok := row[model]; ok {
					cost = c
				}
			}
			if _, err := tx.Exec(
				`INSERT INTO usage_daily(date,tool,model,input,output,cache_read,cache_write,reasoning,total,cost_usd)
				 VALUES(?,?,?,?,?,?,?,?,?,?)`,
				date, sum.Tool, model,
				u.Input, u.Output, u.CacheRead, u.CacheWrite, u.Reasoning, u.Total, cost); err != nil {
				return err
			}
		}
	}
	return nil
}

func writeToolTotals(tx *sql.Tx, sum scan.ToolSummary) error {
	modelsJSON := "{}"
	if len(sum.Models) > 0 {
		if b, err := json.Marshal(sum.Models); err == nil {
			modelsJSON = string(b)
		}
	}
	var cost any
	if sum.CostUSD != 0 {
		cost = sum.CostUSD
	}
	var lastActivity any
	if !sum.LastActivity.IsZero() {
		lastActivity = sum.LastActivity.UTC().Format(time.RFC3339)
	}
	var note any
	if sum.Note != "" {
		note = sum.Note
	}
	pathExists := 0
	if sum.PathExists {
		pathExists = 1
	}
	u := sum.Usage
	_, err := tx.Exec(
		`INSERT INTO tool_totals(tool,input,output,cache_read,cache_write,reasoning,total,cost_usd,sessions,last_activity,models_json,path_exists,note)
		 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
		 ON CONFLICT(tool) DO UPDATE SET
		   input=excluded.input, output=excluded.output, cache_read=excluded.cache_read,
		   cache_write=excluded.cache_write, reasoning=excluded.reasoning, total=excluded.total,
		   cost_usd=excluded.cost_usd, sessions=excluded.sessions, last_activity=excluded.last_activity,
		   models_json=excluded.models_json, path_exists=excluded.path_exists, note=excluded.note`,
		sum.Tool, u.Input, u.Output, u.CacheRead, u.CacheWrite, u.Reasoning, u.Total,
		cost, sum.Sessions, lastActivity, modelsJSON, pathExists, note)
	return err
}

// writeSessions — 세션 기록을 upsert 하고 상한을 넘으면 오래된 것부터 지운다.
func writeSessions(tx *sql.Tx, records []session.Record) error {
	for _, r := range records {
		var startedAt, endedAt any
		if !r.StartedAt.IsZero() {
			startedAt = r.StartedAt.UTC().Format(time.RFC3339)
		}
		if !r.EndedAt.IsZero() {
			endedAt = r.EndedAt.UTC().Format(time.RFC3339)
		}
		modelsJSON := "[]"
		if models := sortedModelKeys(r.Models); len(models) > 0 {
			if b, err := json.Marshal(models); err == nil {
				modelsJSON = string(b)
			}
		}
		var project, branch, firstPrompt any
		if r.ProjectLabel != "" {
			project = r.ProjectLabel
		}
		if r.GitBranch != "" {
			branch = r.GitBranch
		}
		if fp := firstPrompt2(r); fp != "" {
			firstPrompt = fp
		}
		// cache_read 에 세션 캐시 합계를 싣는다(레코드가 read/write 를 분리하지 않음).
		// cost_usd 는 NULL — 서버가 모델 요율로 계산한다.
		if _, err := tx.Exec(
			`INSERT INTO sessions(id,tool,session_id,project,git_branch,started_at,ended_at,input,output,cache_read,cache_write,total,cost_usd,models_json,prompt_count,first_prompt,agent_count)
			 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
			 ON CONFLICT(id) DO UPDATE SET
			   tool=excluded.tool, session_id=excluded.session_id, project=excluded.project,
			   git_branch=excluded.git_branch, started_at=excluded.started_at, ended_at=excluded.ended_at,
			   input=excluded.input, output=excluded.output, cache_read=excluded.cache_read,
			   cache_write=excluded.cache_write, total=excluded.total, models_json=excluded.models_json,
			   prompt_count=excluded.prompt_count, first_prompt=excluded.first_prompt, agent_count=excluded.agent_count`,
			r.ID(), providerTool(r.Provider), r.SessionID, project, branch, startedAt, endedAt,
			r.InputTokens, r.OutputTokens, r.CacheTokens, 0, r.TotalTokens, nil,
			modelsJSON, r.PromptCount, firstPrompt, r.AgentCount); err != nil {
			return err
		}
	}

	// 상한 초과분 정리 — ended_at 이 오래된(또는 NULL) 순으로 삭제.
	_, err := tx.Exec(
		`DELETE FROM sessions WHERE id IN (
		   SELECT id FROM sessions ORDER BY ended_at DESC LIMIT -1 OFFSET ?)`, maxSessions)
	return err
}

// UploadSnapshot — 서버 업로드 전용의 새 SQLite 파일을 만든다.
// 허용 테이블은 정확히 meta와 usage_daily뿐이다. 원본 파일을 복제하지 않으므로
// sessions 테이블이나 삭제된 페이지의 프롬프트 바이트가 dst에 남지 않는다.
func (s *Store) UploadSnapshot(dst string) (err error) {
	_ = os.Remove(dst)
	conn, err := s.db.Conn(context.Background())
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err = conn.ExecContext(context.Background(), `ATTACH DATABASE ? AS upload`, dst); err != nil {
		return err
	}
	ok := false
	defer func() {
		_, detachErr := conn.ExecContext(context.Background(), `DETACH DATABASE upload`)
		if err == nil {
			err = detachErr
		}
		if !ok || err != nil {
			_ = os.Remove(dst)
		}
	}()
	_, err = conn.ExecContext(context.Background(), `
PRAGMA upload.user_version=1;
CREATE TABLE upload.meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE upload.usage_daily(
  date TEXT NOT NULL,
  tool TEXT NOT NULL,
  model TEXT NOT NULL DEFAULT '',
  input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
  cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
  reasoning INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL,
  PRIMARY KEY(date, tool, model));
INSERT INTO upload.meta(key,value) SELECT key,value FROM main.meta;
INSERT INTO upload.usage_daily
  (date,tool,model,input,output,cache_read,cache_write,reasoning,total,cost_usd)
  SELECT date,tool,model,input,output,cache_read,cache_write,reasoning,total,cost_usd
  FROM main.usage_daily;
`)
	if err != nil {
		return err
	}
	ok = true
	return nil
}

// providerTool — 세션 provider("claude"|"codex")를 usage 도구 식별자로 매핑.
func providerTool(provider string) string {
	switch provider {
	case "claude":
		return "claudeCode"
	default:
		return provider
	}
}

// sortedModelKeys — models 맵의 키를 누적 total 내림차순으로.
func sortedModelKeys(models map[string]int64) []string {
	if len(models) == 0 {
		return nil
	}
	keys := make([]string, 0, len(models))
	for k := range models {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if models[keys[i]] != models[keys[j]] {
			return models[keys[i]] > models[keys[j]]
		}
		return keys[i] < keys[j]
	})
	return keys
}

// firstPrompt2 — 세션의 첫 요청 줄(없으면 CurrentTask).
func firstPrompt2(r session.Record) string {
	if len(r.Prompts) > 0 {
		return r.Prompts[0]
	}
	return r.CurrentTask
}
