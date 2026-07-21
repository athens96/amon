package scan

// Cursor 소비 토큰 — 대시보드 사용-이벤트 CSV 폴백 (macOS CursorUsageEvents.swift 와 1:1).
//
// 2026 초 이후 Cursor 는 state.vscdb 버블에 per-request tokenCount 를 기록하지
// 않는다(필드는 남았으나 항상 0 — 2025-12 이후 실측 중단). 로컬 DB 스캔은 과거
// 누적만 남으므로, 같은 DB 의 ItemTable(cursorAuth/accessToken)로 인증해
// export-usage-events-csv?strategy=tokens 를 받아 최근 창의 일자별 소비를 채운다.
// 스캐너 4종 중 유일한 네트워크 예외 — 오프라인/미로그인 시 조용히 DB 값 유지.

import (
	"database/sql"
	"encoding/base64"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const cursorExportCSVURL = "https://cursor.com/api/dashboard/export-usage-events-csv"

// mergeCursorDashboard — CSV 집계를 요약에 병합.
// daily/today 는 CSV 창으로 교체(버블 데이터는 이 창에서 항상 빈 상태),
// 누적은 DB 역사 + CSV 창 합, models/cost 는 CSV 기준(DB 는 원래 미제공).
func mergeCursorDashboard(s *ToolSummary, dbPath string, windowStart time.Time) {
	token := readCursorAccessToken(dbPath)
	if token == "" {
		return
	}
	res := fetchCursorUsageCSV(token, windowStart)
	if res.events == 0 {
		return
	}
	s.Daily = res.daily
	for _, u := range res.daily {
		s.Usage.Add(u)
	}
	s.Today = res.daily[DayKey(time.Now())]
	s.Models = res.models
	s.CostUSD = res.cost
	// 일자×모델·비용도 CSV 로 교체(버블 폴백분은 이 창에서 항상 빈 상태).
	s.DailyByModel = res.dailyByModel
	s.DailyCostByModel = res.dailyCostByModel
	if res.last.After(s.LastActivity) {
		s.LastActivity = res.last
	}
	s.Note = "소비 토큰은 Cursor 대시보드 API 기준"
}

// readCursorAccessToken — 스캔과 같은 state.vscdb 의 ItemTable 에서 액세스 토큰.
// 값이 JSON 문자열("...")로 감싸져 있을 수 있어 벗겨낸다.
func readCursorAccessToken(dbPath string) string {
	dsn := "file:" + url.PathEscape(dbPath) + "?immutable=1&mode=ro"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return ""
	}
	defer db.Close()
	var value string
	if db.QueryRow(
		`SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'`,
	).Scan(&value) != nil {
		return ""
	}
	var unquoted string
	if json.Unmarshal([]byte(value), &unquoted) == nil {
		return unquoted
	}
	return value
}

// cursorTokenUserID — JWT payload 의 sub("auth0|user_x")에서 유저 ID.
func cursorTokenUserID(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Sub string `json:"sub"`
	}
	if json.Unmarshal(payload, &claims) != nil {
		return ""
	}
	if i := strings.IndexByte(claims.Sub, '|'); i >= 0 {
		return claims.Sub[i+1:]
	}
	return claims.Sub
}

// cursorCSVResult — CSV 집계 결과.
type cursorCSVResult struct {
	daily            map[string]TokenUsage
	models           map[string]int64
	dailyByModel     map[string]map[string]TokenUsage
	dailyCostByModel map[string]map[string]float64
	cost             float64
	last             time.Time
	events           int
}

// fetchCursorUsageCSV — CSV 다운로드 + 일자별·모델별 집계.
// 헤더(2026-07 실측): Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,
// Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
func fetchCursorUsageCSV(token string, windowStart time.Time) cursorCSVResult {
	res := cursorCSVResult{
		daily:            map[string]TokenUsage{},
		models:           map[string]int64{},
		dailyByModel:     map[string]map[string]TokenUsage{},
		dailyCostByModel: map[string]map[string]float64{},
	}

	uid := cursorTokenUserID(token)
	if uid == "" {
		return res
	}
	q := url.Values{
		"startDate": {strconv.FormatInt(windowStart.UnixMilli(), 10)},
		"endDate":   {strconv.FormatInt(time.Now().UnixMilli(), 10)},
		"strategy":  {"tokens"},
	}
	req, err := http.NewRequest("GET", cursorExportCSVURL+"?"+q.Encode(), nil)
	if err != nil {
		return res
	}
	req.Header.Set("Cookie", fmt.Sprintf("WorkosCursorSessionToken=%s%%3A%%3A%s", uid, token))
	req.Header.Set("Accept", "text/csv")
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return res
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return res
	}

	reader := csv.NewReader(resp.Body)
	reader.FieldsPerRecord = -1
	header, err := reader.Read()
	if err != nil {
		return res
	}
	col := func(name string) int {
		for i, h := range header {
			if strings.EqualFold(strings.TrimSpace(h), name) {
				return i
			}
		}
		return -1
	}
	iDate, iOut := col("Date"), col("Output Tokens")
	if iDate < 0 || iOut < 0 {
		return res // 필수 컬럼 없음 = 포맷 변경 — 폴백 포기
	}
	iModel := col("Model")
	iCacheW := col("Input (w/ Cache Write)")
	iInput := col("Input (w/o Cache Write)")
	iCacheR := col("Cache Read")
	iTotal := col("Total Tokens")
	iCost := col("Cost")

	intAt := func(rec []string, i int) int64 {
		if i < 0 || i >= len(rec) {
			return 0
		}
		n, _ := strconv.ParseInt(strings.TrimSpace(rec[i]), 10, 64)
		return n
	}

	for {
		rec, err := reader.Read()
		if err != nil {
			break
		}
		if iDate >= len(rec) {
			continue
		}
		t, err := time.Parse(time.RFC3339Nano, rec[iDate])
		if err != nil {
			if t, err = time.Parse(time.RFC3339, rec[iDate]); err != nil {
				continue
			}
		}
		u := TokenUsage{
			Input:      intAt(rec, iInput),
			CacheWrite: intAt(rec, iCacheW),
			CacheRead:  intAt(rec, iCacheR),
			Output:     intAt(rec, iOut),
			Total:      intAt(rec, iTotal),
		}
		if u.Total == 0 {
			u.Total = u.Input + u.Output + u.CacheRead + u.CacheWrite
		}
		if u.Total == 0 {
			continue
		}
		day := DayKey(t.Local())
		d := res.daily[day]
		d.Add(u)
		res.daily[day] = d
		model := ""
		if iModel >= 0 && iModel < len(rec) && rec[iModel] != "" {
			model = rec[iModel]
			res.models[model] += u.Total
		}
		var lineCost float64
		if iCost >= 0 && iCost < len(rec) {
			if c, err := strconv.ParseFloat(strings.TrimSpace(rec[iCost]), 64); err == nil {
				lineCost = c
				res.cost += c
			}
		}
		mergeDailyModel(res.dailyByModel, day, model, u)
		if lineCost != 0 {
			crow := res.dailyCostByModel[day]
			if crow == nil {
				crow = map[string]float64{}
				res.dailyCostByModel[day] = crow
			}
			crow[model] += lineCost
		}
		if t.After(res.last) {
			res.last = t
		}
		res.events++
	}
	return res
}
