package scan

import (
	"database/sql"
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite" // 순수 Go SQLite 드라이버 (cgo 불필요)
)

// ScanOpenCode — 신버전(2025말~) Drizzle SQLite opencode.db 를 우선 스캔하고,
// 없으면 구버전 파일 storage/message 를 폴백으로 읽는다 (macOS 스캐너와 동일).
// dataDir 이 .db 파일을 직접 가리켜도 동작한다.
func ScanOpenCode(dataDir string, windowStart time.Time) ToolSummary {
	s := ToolSummary{
		Tool: "openCode", DisplayName: "OpenCode",
		Daily: map[string]TokenUsage{}, Models: map[string]int64{},
		DailyByModel:     map[string]map[string]TokenUsage{},
		DailyCostByModel: map[string]map[string]float64{}, PathExists: true,
	}

	if strings.HasSuffix(dataDir, ".db") {
		if _, err := os.Stat(dataDir); err != nil {
			s.PathExists = false
			s.Note = "경로를 찾을 수 없습니다"
			return s
		}
		scanOpenCodeDB(&s, dataDir, windowStart)
		return s
	}

	if !dirExists(dataDir) {
		s.PathExists = false
		s.Note = "경로를 찾을 수 없습니다"
		return s
	}

	dbPath := filepath.Join(dataDir, "opencode.db")
	if _, err := os.Stat(dbPath); err == nil {
		scanOpenCodeDB(&s, dbPath, windowStart)
		return s
	}

	// 구버전 파일 storage 폴백.
	messageDir := ""
	for _, cand := range []string{
		filepath.Join(dataDir, "storage", "message"),
		filepath.Join(dataDir, "message"),
		dataDir,
	} {
		if dirExists(cand) {
			messageDir = cand
			break
		}
	}
	if messageDir == "" {
		s.Note = "opencode.db / storage/message 가 없습니다 (미사용?)"
		return s
	}
	scanOpenCodeFiles(&s, messageDir, windowStart)
	return s
}

// opencodeMessage — 메시지 JSON 공통 형태 (db data 컬럼 / 파일 동일).
type opencodeMessage struct {
	Role      string  `json:"role"`
	ModelID   string  `json:"modelID"`
	SessionID string  `json:"sessionID"`
	Cost      float64 `json:"cost"`
	Tokens    *struct {
		Input     int64 `json:"input"`
		Output    int64 `json:"output"`
		Reasoning int64 `json:"reasoning"`
		Cache     *struct {
			Read  int64 `json:"read"`
			Write int64 `json:"write"`
		} `json:"cache"`
	} `json:"tokens"`
	Time *struct {
		Created int64 `json:"created"` // epoch ms
	} `json:"time"`
}

func (m *opencodeMessage) usage() TokenUsage {
	t := m.Tokens
	if t == nil {
		return TokenUsage{}
	}
	var cr, cw int64
	if t.Cache != nil {
		cr, cw = t.Cache.Read, t.Cache.Write
	}
	return TokenUsage{
		Input: t.Input, Output: t.Output,
		CacheRead: cr, CacheWrite: cw, Reasoning: t.Reasoning,
		Total: t.Input + t.Output + cr + cw,
	}
}

func (s *ToolSummary) addOpenCodeMessage(m *opencodeMessage, when time.Time, windowStart time.Time) {
	u := m.usage()
	s.Usage.Add(u)
	s.CostUSD += m.Cost
	if u.Total > 0 && m.ModelID != "" {
		s.Models[m.ModelID] += u.Total
	}
	if m.SessionID != "" {
		// Sessions 는 호출부에서 set 으로 집계 — 여기서는 LastActivity 만.
	}
	if !when.IsZero() {
		if when.After(s.LastActivity) {
			s.LastActivity = when
		}
		if !when.Before(windowStart) {
			dk := DayKey(when)
			day := s.Daily[dk]
			day.Add(u)
			s.Daily[dk] = day
			// 일자×모델 귀속 + 소스가 준 비용(모델 미상은 "" 버킷).
			s.addDailyModel(dk, m.ModelID, u, m.Cost)
		}
	}
}

// scanOpenCodeDB — message 테이블의 data JSON 에서 assistant 메시지를 집계.
// 실행 중 잠금을 피하려 read-only + immutable 로 연다.
func scanOpenCodeDB(s *ToolSummary, dbPath string, windowStart time.Time) {
	dsn := "file:" + url.PathEscape(dbPath) + "?immutable=1&mode=ro"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		s.Note = "opencode.db 를 열 수 없습니다"
		return
	}
	defer db.Close()

	rows, err := db.Query(`SELECT time_created, data FROM message
	                        WHERE json_extract(data, '$.role') = 'assistant'`)
	if err != nil {
		s.Note = "opencode.db message 조회 실패 (스키마 상이?)"
		return
	}
	defer rows.Close()

	sessions := map[string]struct{}{}
	for rows.Next() {
		var createdMs int64
		var data string
		if rows.Scan(&createdMs, &data) != nil {
			continue
		}
		var m opencodeMessage
		if json.Unmarshal([]byte(data), &m) != nil {
			continue
		}
		var when time.Time
		if createdMs > 0 {
			when = time.UnixMilli(createdMs)
		}
		s.addOpenCodeMessage(&m, when, windowStart)
		if m.SessionID != "" {
			sessions[m.SessionID] = struct{}{}
		}
	}
	s.Sessions = len(sessions)
	s.Today = s.Daily[DayKey(time.Now())]
	if s.Usage.Total == 0 {
		s.Note = "opencode.db 에 사용 기록이 없습니다"
	}
}

// scanOpenCodeFiles — 구버전 파일 storage: message/<session>/<message>.json.
func scanOpenCodeFiles(s *ToolSummary, messageDir string, windowStart time.Time) {
	sessions := map[string]struct{}{}
	_ = filepath.WalkDir(messageDir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".json") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		var m opencodeMessage
		if json.Unmarshal(data, &m) != nil || m.Role != "assistant" {
			return nil
		}
		var when time.Time
		if m.Time != nil && m.Time.Created > 0 {
			when = time.UnixMilli(m.Time.Created)
		} else if info, e := d.Info(); e == nil {
			when = info.ModTime()
		}
		s.addOpenCodeMessage(&m, when, windowStart)
		// 세션 ID = 상위 폴더명.
		sessions[filepath.Base(filepath.Dir(path))] = struct{}{}
		return nil
	})
	s.Sessions = len(sessions)
	s.Today = s.Daily[DayKey(time.Now())]
	if s.Sessions == 0 {
		s.Note = "사용 기록이 없습니다"
	}
}
