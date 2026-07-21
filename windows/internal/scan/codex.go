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

// codexTokenUsage — rollout token_count 이벤트의 usage 블록.
type codexTokenUsage struct {
	Input     int64 `json:"input_tokens"`
	Cached    int64 `json:"cached_input_tokens"`
	Output    int64 `json:"output_tokens"`
	Reasoning int64 `json:"reasoning_output_tokens"`
	Total     int64 `json:"total_tokens"`
}

type codexEvent struct {
	Timestamp string `json:"timestamp"`
	Payload   struct {
		Type string `json:"type"`
		Info *struct {
			Total *codexTokenUsage `json:"total_token_usage"`
			Last  *codexTokenUsage `json:"last_token_usage"`
		} `json:"info"`
		Model string `json:"model"` // turn_context 전용
	} `json:"payload"`
}

// 라인 프리필터 토큰 — 라인 문자열 복사 없이 bytes 로 검사한다.
var (
	codexTokenCountToken  = []byte(`"token_count"`)
	codexTurnContextToken = []byte(`"turn_context"`)
)

// ScanCodex — 각 rollout 파일의 마지막 token_count 가 그 세션의 누적 사용량이다.
// 라인마다 더하면 중복 계산되므로 세션별 마지막 스냅샷만 합산하고, 일자별은
// 창 내 token_count 이벤트의 last_token_usage(턴 단건)를 이벤트 날짜로 귀속한다
// (자정 넘김 세션도 날짜별 분리). Σ턴단건이 최종 누적과 어긋나는 파일이 실측
// ~17% 존재해(중단/재시도 턴 미반영, 2026-07 +1.5%) 최종 누적을 권위값으로
// 턴 기여분을 비례 스케일링한다 — 맥 UsageScanner.parseCodexFile 과 동일 규칙.
//
// 지문(mtime+size)이 직전 스캔과 같은 파일은 다시 읽지 않고 캐시된 세션
// 스냅샷을 합산한다 — rollout 은 세션 종료 후 불변이다.
// codexOrcaSessions — 설정 경로 외에 함께 읽는 격리 런타임 홈(호스트 앱이 쓰는
// CODEX_HOME). 맥 codexSessionPaths 의 Orca 폴백과 동일. 테스트에서 교체 가능하도록 var.
var codexOrcaSessions = defaultCodexOrcaSessions()

func defaultCodexOrcaSessions() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home,
		"Library", "Application Support", "orca", "codex-runtime-home", "home", "sessions")
}

// codexRoots — Codex 세션 루트 후보. 설정 경로(primary)를 우선하고, Orca 런타임
// 세션 홈이 있으면 함께 읽는다(맥 UsageScanner.codexSessionPaths 와 동일 규칙).
// EvalSymlinks(실패 시 Clean)로 정규화해 같은 디렉토리를 중복 walk 하지 않는다.
func codexRoots(primary string) []string {
	candidates := []string{primary}
	if codexOrcaSessions != "" {
		candidates = append(candidates, codexOrcaSessions)
	}
	seen := map[string]struct{}{}
	var roots []string
	for _, c := range candidates {
		if c == "" {
			continue
		}
		norm, err := filepath.EvalSymlinks(c)
		if err != nil {
			norm = filepath.Clean(c)
		}
		if _, dup := seen[norm]; dup {
			continue
		}
		seen[norm] = struct{}{}
		roots = append(roots, norm)
	}
	return roots
}

func ScanCodex(root string, windowStart time.Time) ToolSummary {
	s := ToolSummary{
		Tool: "codex", DisplayName: "Codex CLI",
		Daily: map[string]TokenUsage{}, Models: map[string]int64{},
		DailyByModel: map[string]map[string]TokenUsage{}, PathExists: true,
	}

	roots := codexRoots(root)
	visited := map[string]struct{}{}
	// rollout 파일명(rollout-<ts>-<sessionId>.jsonl)은 세션당 전역 유일하다. 격리 홈이
	// 설정 경로의 세션을 하드링크/복제로 공유할 수 있어(같은 세션이 두 root 에 등장),
	// 파일명 기준으로 세션을 한 번만 센다 — 두 root 합산 시 중복 집계 방지.
	seenBase := map[string]struct{}{}
	windowKey := DayKey(windowStart)
	var latest time.Time
	anyExists := false

	scanCache.Lock()
	defer scanCache.Unlock()

	for _, cr := range roots {
		if !dirExists(cr) {
			continue
		}
		anyExists = true
		_ = filepath.WalkDir(cr, func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() || !strings.HasSuffix(path, ".jsonl") {
				return nil
			}
			base := filepath.Base(path)
			if _, dup := seenBase[base]; dup {
				return nil // 다른 root 에서 이미 센 세션 (하드링크/복제)
			}
			seenBase[base] = struct{}{}
			visited[path] = struct{}{}

			info, _ := d.Info()
			var mtime time.Time
			var size int64
			if info != nil {
				mtime = info.ModTime()
				size = info.Size()
			}
			fp := fingerprint(mtime, size)

			entry := scanCache.codex[path]
			if entry == nil || entry.fp != fp {
				entry = parseCodexFile(path, mtime, windowStart)
				if entry == nil {
					delete(scanCache.codex, path)
					return nil
				}
				entry.fp = fp
				scanCache.codex[path] = entry
			}
			if !entry.hasData {
				return nil
			}

			s.Usage.Add(entry.session)
			s.Sessions++
			if mtime.After(latest) {
				latest = mtime
			}
			if entry.session.Total > 0 {
				s.Models[entry.model] += entry.session.Total
			}
			for day, u := range entry.daily {
				if day >= windowKey {
					dd := s.Daily[day]
					dd.Add(u)
					s.Daily[day] = dd
				}
			}
			for day, byModel := range entry.dailyByModel {
				if day < windowKey {
					continue
				}
				for model, u := range byModel {
					s.addDailyModel(day, model, u, 0)
				}
			}
			return nil
		})
	}

	sweepCodexCache(visited)

	if !anyExists {
		s.PathExists = false
		s.Note = "경로를 찾을 수 없습니다"
		return s
	}
	s.LastActivity = latest
	s.Today = s.Daily[DayKey(time.Now())]
	if s.Sessions == 0 {
		s.Note = "토큰 기록이 있는 세션이 없습니다"
	}
	return s
}

// parseCodexFile — rollout 파일 하나를 파싱해 캐시 항목을 만든다.
// 열기 실패 시 nil, token_count 가 없거나 깨진 파일은 hasData=false 로 기억해
// 다음 스캔에서 재읽기를 피한다.
func parseCodexFile(path string, mtime time.Time, windowStart time.Time) *codexFileEntry {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	mayHaveWindow := !mtime.Before(windowStart)

	// 마지막 token_count 라인(세션 누적)만 보관하고, 창 내 파일이면 일자×모델
	// 귀속용으로 token_count 라인 전체를 그 시점의 현재 모델과 함께 모은다.
	// 현재 모델 = 그 라인까지 마지막 turn_context.payload.model (없으면 "unknown").
	var lastTokenLine string
	runModel := "unknown"
	type winTok struct {
		line  string
		model string
	}
	var windowTokenLines []winTok
	sc := bufio.NewScanner(f)
	// 초기 64KB, 최대 32MB — 긴 라인은 필요할 때만 버퍼가 자란다.
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if bytes.Contains(line, codexTokenCountToken) {
			lastTokenLine = string(line) // 매칭 라인만 문자열화
			if mayHaveWindow {
				windowTokenLines = append(windowTokenLines, winTok{lastTokenLine, runModel})
			}
		} else if bytes.Contains(line, codexTurnContextToken) {
			var tc codexEvent
			if json.Unmarshal(line, &tc) == nil && tc.Payload.Model != "" {
				runModel = tc.Payload.Model
			}
		}
	}

	e := &codexFileEntry{daily: map[string]TokenUsage{}, dailyByModel: map[string]map[string]TokenUsage{}}
	if lastTokenLine == "" {
		return e
	}
	var ev codexEvent
	if json.Unmarshal([]byte(lastTokenLine), &ev) != nil ||
		ev.Payload.Info == nil || ev.Payload.Info.Total == nil {
		return e
	}
	tu := ev.Payload.Info.Total
	total := tu.Total
	if total == 0 {
		total = tu.Input + tu.Output
	}
	// 브레이크다운 합이 total 과 맞도록 캐시분을 input 에서 분리.
	e.session = TokenUsage{
		Input:     max64(0, tu.Input-tu.Cached),
		Output:    tu.Output,
		CacheRead: tu.Cached,
		Reasoning: tu.Reasoning,
		Total:     total,
	}
	e.hasData = true

	// 세션 토큰을 마지막 turn_context 의 모델에 귀속. 구버전 rollout 은
	// turn_context 가 없어 "unknown" 버킷으로 모은다.
	e.model = runModel

	// Σ(턴 단건)이 최종 누적과 다른 파일이 있다(중단/재시도 턴 미반영) — 최종
	// 누적이 권위값이므로 턴 기여분을 비례 스케일링해 일자 버킷을 정합시킨다.
	type turnBucket struct {
		day   string
		model string
		usage TokenUsage
	}
	var sumTurnTotal int64
	var turns []turnBucket
	for _, wt := range windowTokenLines {
		var te codexEvent
		if json.Unmarshal([]byte(wt.line), &te) != nil ||
			te.Payload.Info == nil || te.Payload.Info.Last == nil { // info:null 하트비트 제외
			continue
		}
		lu := te.Payload.Info.Last
		lt := lu.Total
		if lt == 0 {
			lt = lu.Input + lu.Output
		}
		u := TokenUsage{
			Input:     max64(0, lu.Input-lu.Cached),
			Output:    lu.Output,
			CacheRead: lu.Cached,
			Reasoning: lu.Reasoning,
			Total:     lt,
		}
		// 스케일 분모는 창 여부와 무관하게 파일의 모든 턴 합.
		sumTurnTotal += lt
		ts, err := time.Parse(time.RFC3339, te.Timestamp)
		if err != nil || ts.Before(windowStart) {
			continue
		}
		turns = append(turns, turnBucket{DayKey(ts), wt.model, u})
	}
	factor := 1.0
	if sumTurnTotal > 0 && e.session.Total > 0 {
		factor = float64(e.session.Total) / float64(sumTurnTotal)
	}
	for _, t := range turns {
		u := t.usage
		if factor < 0.9999 || factor > 1.0001 {
			u = scaleUsage(u, factor)
		}
		dd := e.daily[t.day]
		dd.Add(u)
		e.daily[t.day] = dd
		mergeDailyModel(e.dailyByModel, t.day, t.model, u)
	}
	return e
}

// scaleUsage — 각 축을 비율로 줄이거나 늘린(반올림) 사본. Codex 일자 보정용.
func scaleUsage(u TokenUsage, factor float64) TokenUsage {
	s := func(n int64) int64 { return int64(float64(n)*factor + 0.5) }
	return TokenUsage{
		Input:      s(u.Input),
		Output:     s(u.Output),
		CacheRead:  s(u.CacheRead),
		CacheWrite: s(u.CacheWrite),
		Reasoning:  s(u.Reasoning),
		Total:      s(u.Total),
	}
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
