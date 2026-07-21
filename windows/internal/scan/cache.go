package scan

import (
	"encoding/binary"
	"hash/fnv"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// 스캔 간 파일별 결과 캐시.
//
// A-mon 은 10분마다 로그 트리 전체를 다시 읽는데, 세션 로그는 한 번 닫히면
// 불변이다. 파일 지문(mtime+size)이 직전 스캔과 같으면 열지도 파싱하지도 않고
// 캐시된 기여분을 그대로 합산한다 — 정상 사이클의 I/O 가 "트리 전체"에서
// "활성 파일 몇 개"로 줄어든다. 맥 앱(UsageScanner.swift)과 동일 구조.

// fileFP — 파일 변경 감지 지문. mtime+size 가 같으면 내용이 같다고 본다.
type fileFP struct {
	mtimeNs int64
	size    int64
}

// contribution — 한 파일이 도구 요약에 더하는 값(파일 내 dedup 적용 후).
// daily 는 절대 날짜 키로 저장하고, 합산 시점의 창 시작(windowKey)으로 걸러
// 쓴다 — 창이 앞으로 굴러도 캐시를 무효화할 필요가 없다.
type contribution struct {
	usage        TokenUsage
	models       map[string]int64
	daily        map[string]TokenUsage
	dailyByModel map[string]map[string]TokenUsage // date -> model -> usage (창 무관, addTo 에서 필터)
}

// addTo — 기여분을 요약에 합산한다. daily 는 windowKey("2006-01-02") 이후만.
func (c *contribution) addTo(s *ToolSummary, windowKey string) {
	s.Usage.Add(c.usage)
	for m, v := range c.models {
		s.Models[m] += v
	}
	for day, u := range c.daily {
		if day >= windowKey {
			d := s.Daily[day]
			d.Add(u)
			s.Daily[day] = d
		}
	}
	for day, byModel := range c.dailyByModel {
		if day < windowKey {
			continue
		}
		for model, u := range byModel {
			s.addDailyModel(day, model, u, 0)
		}
	}
}

// addDailyModel — contribution 내 dailyByModel[day][model] 누적 (지연 초기화).
func (c *contribution) addDailyModel(day, model string, u TokenUsage) {
	if c.dailyByModel == nil {
		c.dailyByModel = map[string]map[string]TokenUsage{}
	}
	mergeDailyModel(c.dailyByModel, day, model, u)
}

// mergeDailyModel — m[day][model] 에 usage 를 누적하는 공용 프리미티브 (m 은 non-nil).
func mergeDailyModel(m map[string]map[string]TokenUsage, day, model string, u TokenUsage) {
	row := m[day]
	if row == nil {
		row = map[string]TokenUsage{}
		m[day] = row
	}
	cur := row[model]
	cur.Add(u)
	row[model] = cur
}

// claudeFileEntry — Claude 세션 파일 하나의 캐시.
type claudeFileEntry struct {
	fp   fileFP
	keys []uint64     // 파일 내 dedup 후 non-anon 키 해시 (등장 순)
	full contribution // 모든 키를 이 파일이 가진다고 볼 때의 기여분
	// variants — 파일 간 dedup(--resume 복사)으로 일부 키를 앞 파일에 빼앗겼을
	// 때의 기여분. 키는 잃은 키 목록의 다이제스트 — 겹침은 안정적이라 보통 0~1개.
	variants map[uint64]contribution
}

// codexFileEntry — Codex rollout 파일 하나의 캐시. 파일 간 dedup 이 없어
// 기여분이 자기완결적이다.
type codexFileEntry struct {
	fp           fileFP
	hasData      bool // 파싱 가능한 token_count 라인이 있었는지 (없는 파일도 기억해 재읽기 방지)
	session      TokenUsage
	model        string
	daily        map[string]TokenUsage
	dailyByModel map[string]map[string]TokenUsage // date -> model(그 시점 turn_context) -> usage
}

// toolFileEntry — 단순 프로바이더(gemini·qwen·copilot)의 파일별 캐시.
// 이들은 파일 간 dedup 이 없어 기여분이 자기완결적이다(codexFileEntry 와 유사).
// 세션 수는 파일당 세션 ID 로 세므로 캐시 적중에도 셀 수 있게 목록을 보관한다.
type toolFileEntry struct {
	fp           fileFP
	hasData      bool // 파싱 가능한 파일이었는지 (깨진/빈 파일도 기억해 재읽기 방지)
	usage        TokenUsage
	models       map[string]int64
	daily        map[string]TokenUsage
	dailyByModel map[string]map[string]TokenUsage
	sessionIDs   []string // 이 파일이 기여하는 고유 세션 식별자 (보통 1개)
	lastActivity time.Time
}

func newToolFileEntry() *toolFileEntry {
	return &toolFileEntry{
		models:       map[string]int64{},
		daily:        map[string]TokenUsage{},
		dailyByModel: map[string]map[string]TokenUsage{},
	}
}

// add — 파싱 중 한 메시지(또는 이벤트)의 기여분을 누적한다. day 귀속은 ts 가
// 창 안일 때만. model 이 ""(미상)이면 모델별 누적은 건너뛰되 daily 는 "" 버킷에 넣는다.
func (e *toolFileEntry) add(u TokenUsage, model string, ts, windowStart time.Time) {
	e.usage.Add(u)
	e.hasData = true
	if u.Total > 0 && model != "" {
		e.models[model] += u.Total
	}
	if ts.After(e.lastActivity) {
		e.lastActivity = ts
	}
	if !ts.IsZero() && !ts.Before(windowStart) {
		day := DayKey(ts)
		d := e.daily[day]
		d.Add(u)
		e.daily[day] = d
		mergeDailyModel(e.dailyByModel, day, model, u)
	}
}

// mergeInto — 엔트리를 요약에 합산(daily 는 windowKey 이후만)하고, 세션 ID 를 set 에 넣는다.
func (e *toolFileEntry) mergeInto(s *ToolSummary, windowKey string, sessions map[string]struct{}) {
	s.Usage.Add(e.usage)
	for m, v := range e.models {
		s.Models[m] += v
	}
	for day, u := range e.daily {
		if day >= windowKey {
			d := s.Daily[day]
			d.Add(u)
			s.Daily[day] = d
		}
	}
	for day, byModel := range e.dailyByModel {
		if day < windowKey {
			continue
		}
		for model, u := range byModel {
			s.addDailyModel(day, model, u, 0)
		}
	}
	for _, id := range e.sessionIDs {
		if id != "" {
			sessions[id] = struct{}{}
		}
	}
	if e.lastActivity.After(s.LastActivity) {
		s.LastActivity = e.lastActivity
	}
}

// scanCache — 프로세스 수명 동안 유지되는 파일별 캐시. 트레이 루프에서 스캔은
// 직렬이지만 안전하게 잠근다.
var scanCache = struct {
	sync.Mutex
	claude  map[string]*claudeFileEntry
	codex   map[string]*codexFileEntry
	gemini  map[string]*toolFileEntry
	qwen    map[string]*toolFileEntry
	copilot map[string]*toolFileEntry
}{
	claude:  map[string]*claudeFileEntry{},
	codex:   map[string]*codexFileEntry{},
	gemini:  map[string]*toolFileEntry{},
	qwen:    map[string]*toolFileEntry{},
	copilot: map[string]*toolFileEntry{},
}

// ResetScanCache — 테스트용: 캐시를 비워 콜드 스캔 상태로 되돌린다.
func ResetScanCache() {
	scanCache.Lock()
	scanCache.claude = map[string]*claudeFileEntry{}
	scanCache.codex = map[string]*codexFileEntry{}
	scanCache.gemini = map[string]*toolFileEntry{}
	scanCache.qwen = map[string]*toolFileEntry{}
	scanCache.copilot = map[string]*toolFileEntry{}
	scanCache.Unlock()
}

// sweepToolCache — 이번 스캔에서 보이지 않은 파일 항목 제거. 잠금 보유 상태에서 호출.
func sweepToolCache(cache map[string]*toolFileEntry, visited map[string]struct{}) {
	for p := range cache {
		if _, ok := visited[p]; !ok {
			delete(cache, p)
		}
	}
}

// scanWalkFiles — root 아래에서 match 를 통과하는 파일을 지문 캐시로 파싱·합산하는
// 공용 스켈레톤 (gemini·qwen 처럼 파일 간 dedup 이 없는 도구용). s.Sessions·Today 를 채운다.
func scanWalkFiles(
	s *ToolSummary, root string, windowStart time.Time,
	cache map[string]*toolFileEntry,
	match func(base string) bool,
	parse func(path string, windowStart time.Time) *toolFileEntry,
) {
	sessions := map[string]struct{}{}
	visited := map[string]struct{}{}
	windowKey := DayKey(windowStart)

	scanCache.Lock()
	defer scanCache.Unlock()

	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !match(filepath.Base(path)) {
			return nil
		}
		visited[path] = struct{}{}

		info, _ := d.Info()
		var mtime time.Time
		var size int64
		if info != nil {
			mtime = info.ModTime()
			size = info.Size()
		}
		fp := fingerprint(mtime, size)

		entry := cache[path]
		if entry == nil || entry.fp != fp {
			entry = parse(path, windowStart)
			if entry == nil {
				delete(cache, path)
				return nil
			}
			entry.fp = fp
			cache[path] = entry
		}
		entry.mergeInto(s, windowKey, sessions)
		return nil
	})

	sweepToolCache(cache, visited)
	s.Sessions = len(sessions)
	s.Today = s.Daily[DayKey(time.Now())]
}

// fingerprint — WalkDir 의 DirEntry 에서 지문을 만든다. Info 실패 시 zero 값
// (다음 스캔과 비교돼도 mtime 0 끼리라 동작엔 지장 없음).
func fingerprint(mtime time.Time, size int64) fileFP {
	return fileFP{mtimeNs: mtime.UnixNano(), size: size}
}

// hashKey — dedup 키의 64-bit FNV-1a 해시. 키 문자열 대신 해시만 캐시에 남겨
// 메모리를 메시지당 8바이트로 억제한다 (충돌 확률은 수백만 키에서도 ~1e-8).
// 맥 앱과 같은 알고리즘을 쓴다 — 파싱 패리티 유지.
func hashKey(s string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(s))
	return h.Sum64()
}

// lostDigest — 잃은 키 목록(entry.keys 등장 순)의 안정 다이제스트.
func lostDigest(lost []uint64) uint64 {
	h := fnv.New64a()
	var b [8]byte
	for _, k := range lost {
		binary.LittleEndian.PutUint64(b[:], k)
		h.Write(b[:])
	}
	return h.Sum64()
}

// sweepClaudeCache / sweepCodexCache — 이번 스캔에서 보이지 않은 파일의 항목
// 제거 (삭제된 파일·루트 변경). 호출부가 scanCache 잠금을 쥔 상태여야 한다.
func sweepClaudeCache(visited map[string]struct{}) {
	for p := range scanCache.claude {
		if _, ok := visited[p]; !ok {
			delete(scanCache.claude, p)
		}
	}
}

func sweepCodexCache(visited map[string]struct{}) {
	for p := range scanCache.codex {
		if _, ok := visited[p]; !ok {
			delete(scanCache.codex, p)
		}
	}
}
