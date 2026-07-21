package scan

import (
	"database/sql"
	"net/url"
	"os"
	"strings"
	"time"
)

// ScanCursor — Cursor(VS Code fork) state.vscdb 의 cursorDiskKV 에서 토큰을 집계.
//
// bubbleId:<대화>:<버블> 값의 tokenCount.{inputTokens,outputTokens} (캐시 분해
// 없음). 버블에 시각이 없으므로 부모 composerData:<대화> 의 createdAt 로 일자를
// 근사한다. tokenCount 는 원래 assistant 버블의 ~5%(에이전틱 요청)에만 기록된다.
func ScanCursor(dbPath string, windowStart time.Time) ToolSummary {
	s := ToolSummary{
		Tool: "cursor", DisplayName: "Cursor",
		Daily: map[string]TokenUsage{}, Models: map[string]int64{},
		DailyByModel:     map[string]map[string]TokenUsage{},
		DailyCostByModel: map[string]map[string]float64{}, PathExists: true,
	}
	if _, err := os.Stat(dbPath); err != nil {
		s.PathExists = false
		s.Note = "state.vscdb 를 찾을 수 없습니다"
		return s
	}

	dsn := "file:" + url.PathEscape(dbPath) + "?immutable=1&mode=ro"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		s.Note = "state.vscdb 를 열 수 없습니다"
		return s
	}
	defer db.Close()

	// 1) 토큰이 있는 버블만 조회.
	rows, err := db.Query(`
		SELECT key,
		       json_extract(value, '$.tokenCount.inputTokens'),
		       json_extract(value, '$.tokenCount.outputTokens')
		  FROM cursorDiskKV
		 WHERE key LIKE 'bubbleId:%'
		   AND (json_extract(value, '$.tokenCount.inputTokens') > 0
		        OR json_extract(value, '$.tokenCount.outputTokens') > 0)`)
	if err != nil {
		s.Note = "cursorDiskKV 조회 실패 (형식 상이?)"
		return s
	}
	type bubble struct {
		composer      string
		input, output int64
	}
	var bubbles []bubble
	composers := map[string]struct{}{}
	for rows.Next() {
		var key string
		var input, output sql.NullInt64
		if rows.Scan(&key, &input, &output) != nil {
			continue
		}
		parts := strings.SplitN(key, ":", 3)
		if len(parts) < 2 {
			continue
		}
		bubbles = append(bubbles, bubble{parts[1], input.Int64, output.Int64})
		composers[parts[1]] = struct{}{}
	}
	rows.Close()

	if len(bubbles) == 0 {
		s.Note = "토큰 기록이 있는 대화가 없습니다"
		mergeCursorDashboard(&s, dbPath, windowStart)
		return s
	}

	// 2) 대화별 생성일 — 토큰 있는 대화만 키 지정 조회.
	composerDay := map[string]string{}
	stmt, err := db.Prepare(`SELECT json_extract(value, '$.createdAt') FROM cursorDiskKV WHERE key = ?`)
	if err == nil {
		for cid := range composers {
			var ms sql.NullInt64
			if stmt.QueryRow("composerData:"+cid).Scan(&ms) == nil && ms.Int64 > 0 {
				composerDay[cid] = DayKey(time.UnixMilli(ms.Int64))
			}
		}
		stmt.Close()
	}

	// 3) 집계: 전체 누적 + 창 내 일자별. 캐시는 없으므로 0.
	windowKey := DayKey(windowStart) // "2006-01-02" 문자열 비교 = 시간순
	latestDay := ""
	for _, b := range bubbles {
		u := TokenUsage{Input: b.input, Output: b.output, Total: b.input + b.output}
		s.Usage.Add(u)
		if day, ok := composerDay[b.composer]; ok {
			if day >= windowKey {
				d := s.Daily[day]
				d.Add(u)
				s.Daily[day] = d
				// 버블에는 모델 정보가 없어 "" 버킷에 귀속(SPEC §2-1). 비용도 미제공.
				s.addDailyModel(day, "", u, 0)
			}
			if day > latestDay {
				latestDay = day
			}
		}
	}

	s.Sessions = len(composers)
	s.Today = s.Daily[DayKey(time.Now())]
	if latestDay != "" {
		if t, err := time.ParseInLocation("2006-01-02", latestDay, time.Local); err == nil {
			s.LastActivity = t
		}
	}
	// 최신 Cursor 는 버블에 tokenCount 를 안 남기므로(2025-12 이후 항상 0)
	// 대시보드 CSV 로 최근 창을 채운다 — cursor_events.go, macOS 와 동일 규칙.
	mergeCursorDashboard(&s, dbPath, windowStart)
	return s
}
