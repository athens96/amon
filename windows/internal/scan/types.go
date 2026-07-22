// Package scan — 로컬 AI 도구 로그를 읽어 토큰 사용량을 집계한다.
//
// macOS 앱(macos/UsageScanner.swift)과 동일한 파싱 규칙을 유지한다:
//   - Claude Code: (message.id, requestId) 단위 last-wins dedup (블록 반복 기록 보정)
//   - Codex: 세션별 마지막 total_token_usage 스냅샷 + 창 내 턴별 일자 귀속
//   - OpenCode: 신버전 opencode.db(SQLite) 우선, 구버전 파일 storage 폴백
//   - Cursor: state.vscdb 의 bubbleId tokenCount, 대화 생성일로 일자 근사
package scan

import "time"

// ScanWindowDays — 로컬 usage.db(store)에 채우는 일자별 창 (오늘 포함 최근 30일).
// 스캐너는 이 창으로 Daily/DailyByModel 을 채운다 (SPEC §1). 창 이전 날짜 행은
// store 가 과거 스캔의 것을 그대로 보존해 역사를 쌓는다.
const ScanWindowDays = 30

// TokenUsage — 정규화된 토큰 사용량. 도구별 세부 명칭이 달라도 동일 축으로 모은다.
type TokenUsage struct {
	Input      int64 // 순수 입력 (캐시 히트 제외)
	Output     int64
	CacheRead  int64
	CacheWrite int64
	Reasoning  int64 // output 의 부분집합일 수 있어 합계 미포함
	Total      int64
}

// Add 는 u 에 v 를 누적한다.
func (u *TokenUsage) Add(v TokenUsage) {
	u.Input += v.Input
	u.Output += v.Output
	u.CacheRead += v.CacheRead
	u.CacheWrite += v.CacheWrite
	u.Reasoning += v.Reasoning
	u.Total += v.Total
}

// ToolSummary — 한 도구에 대한 스캔 결과 요약.
type ToolSummary struct {
	Tool        string // 로컬 저장 식별자: claudeCode | codex | openCode | cursor | gemini | qwen | copilot (맥과 동일)
	DisplayName string
	Usage       TokenUsage            // 전체 누적
	Today       TokenUsage            // 오늘(로컬 자정 이후)
	Daily       map[string]TokenUsage // 스캔 창(30일), 키는 로컬 "2006-01-02"
	// DailyByModel — 창 내 일자×모델별 사용량 (store usage_daily 의 행 단위). SPEC §2-1.
	DailyByModel map[string]map[string]TokenUsage // date -> model -> usage
	// DailyCostByModel — 소스가 비용을 직접 주는 도구(openCode·cursor)만 채운다. 없으면 빈 맵.
	DailyCostByModel map[string]map[string]float64 // date -> model -> cost(USD)
	Models           map[string]int64              // 모델별 전체 누적 (total 축)
	CostUSD          float64                       // OpenCode·Cursor 만 제공
	Sessions         int
	LastActivity     time.Time
	PathExists       bool
	Note             string // 사용자 안내 (없으면 "")
}

// addDailyModel — DailyByModel[day][model] 에 usage 를, cost>0 이면 DailyCostByModel 에도 누적.
// 맵은 지연 초기화한다(스캐너가 항상 만들지만 방어적으로).
func (s *ToolSummary) addDailyModel(day, model string, u TokenUsage, cost float64) {
	if s.DailyByModel == nil {
		s.DailyByModel = map[string]map[string]TokenUsage{}
	}
	row := s.DailyByModel[day]
	if row == nil {
		row = map[string]TokenUsage{}
		s.DailyByModel[day] = row
	}
	cur := row[model]
	cur.Add(u)
	row[model] = cur
	if cost != 0 {
		if s.DailyCostByModel == nil {
			s.DailyCostByModel = map[string]map[string]float64{}
		}
		crow := s.DailyCostByModel[day]
		if crow == nil {
			crow = map[string]float64{}
			s.DailyCostByModel[day] = crow
		}
		crow[model] += cost
	}
}

// DayKey — Date → 로컬 "2006-01-02".
func DayKey(t time.Time) string { return t.Local().Format("2006-01-02") }

// WindowStart — 스캔 창의 시작(로컬 자정), 오늘 포함 최근 ScanWindowDays 일.
// 스캐너가 채우는 Daily/DailyByModel 의 하한이다.
func WindowStart(now time.Time) time.Time {
	return windowStartDays(now, ScanWindowDays)
}

func windowStartDays(now time.Time, days int) time.Time {
	local := now.Local()
	midnight := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.Local)
	return midnight.AddDate(0, 0, -(days - 1))
}
