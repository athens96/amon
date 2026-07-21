package scan

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// claudeMessage — 한 API 응답의 dedup 단위별 최종 상태 (last-wins).
type claudeMessage struct {
	input, output, cacheWrite, cacheRead int64
	ts                                   time.Time
	model                                string
}

// usage 라인 프리필터 토큰 — 라인 문자열 복사 없이 bytes 로 검사한다.
var claudeUsageToken = []byte(`"usage"`)

// ScanClaude 는 ~/.claude/projects 아래 세션 JSONL 의 assistant usage 를
// (message.id, requestId) 단위 last-wins 로 dedup 해 합산한다.
//
// Claude Code 는 한 API 응답을 콘텐츠 블록마다 별도 라인으로 반복 기록하고
// (같은 message.id, usage 는 동일하거나 스트리밍 중 증가), 그대로 합산하면
// 실사용의 ~2.4배로 부풀려진다. 재등장 시 usage 는 증가만 하므로 마지막 값을
// 채택한다. 파일 간 재등장(--resume 복사)은 먼저 만난 파일이 이긴다.
//
// 지문(mtime+size)이 직전 스캔과 같은 파일은 다시 읽지 않고 캐시된 기여분을
// 합산한다 — 세션 로그는 닫히면 불변이라 정상 사이클엔 활성 파일만 파싱된다.
func ScanClaude(root string, windowStart time.Time) ToolSummary {
	s := ToolSummary{
		Tool: "claudeCode", DisplayName: "Claude Code",
		Daily: map[string]TokenUsage{}, Models: map[string]int64{},
		DailyByModel: map[string]map[string]TokenUsage{}, PathExists: true,
	}
	if !dirExists(root) {
		s.PathExists = false
		s.Note = "경로를 찾을 수 없습니다"
		return s
	}

	sessions := map[string]struct{}{}
	seen := map[uint64]struct{}{} // 파일 간 dedup — 앞 파일이 가져간 키 해시
	visited := map[string]struct{}{}
	windowKey := DayKey(windowStart)
	var latest time.Time

	scanCache.Lock()
	defer scanCache.Unlock()

	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".jsonl") {
			return nil
		}
		base := filepath.Base(path)
		if strings.HasPrefix(base, ".") {
			return nil
		}
		sessions[strings.TrimSuffix(base, ".jsonl")] = struct{}{}
		visited[path] = struct{}{}

		info, _ := d.Info()
		var mtime time.Time
		var size int64
		if info != nil {
			mtime = info.ModTime()
			size = info.Size()
			if mtime.After(latest) {
				latest = mtime
			}
		}
		fp := fingerprint(mtime, size)

		entry := scanCache.claude[path]
		if entry == nil || entry.fp != fp {
			// 파일이 새로 생겼거나 변경됨 — 전체 파싱.
			parsed, effective := parseClaudeFile(path, mtime, windowStart, seen)
			if parsed == nil {
				delete(scanCache.claude, path)
				return nil
			}
			parsed.fp = fp
			scanCache.claude[path] = parsed
			effective.addTo(&s, windowKey)
			for _, k := range parsed.keys {
				seen[k] = struct{}{}
			}
			return nil
		}

		// 캐시 적중 — 앞 파일에 빼앗긴 키(lost)가 있으면 변형 기여분을 쓴다.
		var lost []uint64
		for _, k := range entry.keys {
			if _, dup := seen[k]; dup {
				lost = append(lost, k)
			}
		}
		if len(lost) == 0 {
			entry.full.addTo(&s, windowKey)
		} else if v, ok := entry.variants[lostDigest(lost)]; ok {
			v.addTo(&s, windowKey)
		} else {
			// 이 lost 조합은 처음 — 한 번 재파싱해 변형을 캐시한다 (겹침은
			// 안정적이라 이후 스캔부터는 재파싱 없음).
			parsed, effective := parseClaudeFile(path, mtime, windowStart, seen)
			if parsed == nil {
				delete(scanCache.claude, path)
				return nil
			}
			parsed.fp = fp
			scanCache.claude[path] = parsed
			effective.addTo(&s, windowKey)
			entry = parsed
		}
		for _, k := range entry.keys {
			seen[k] = struct{}{}
		}
		return nil
	})

	sweepClaudeCache(visited)

	s.Sessions = len(sessions)
	s.LastActivity = latest
	s.Today = s.Daily[DayKey(time.Now())]
	if s.Sessions == 0 {
		s.Note = "세션 로그가 없습니다"
	}
	return s
}

// parseClaudeFile — 파일 하나를 파싱해 캐시 항목과, 현재 seen(앞 파일이 가져간
// 키) 기준의 실제 기여분(effective)을 돌려준다. 열기 실패 시 (nil, zero).
func parseClaudeFile(path string, mtime time.Time, windowStart time.Time,
	seen map[uint64]struct{}) (*claudeFileEntry, contribution) {

	f, err := os.Open(path)
	if err != nil {
		return nil, contribution{}
	}
	defer f.Close()

	// 파일이 창 시작 이전에 마지막 수정됐다면 창 내 데이터가 있을 수 없다.
	mayHaveWindow := mtime.After(windowStart) || mtime.Equal(windowStart)

	byMessage := map[string]*claudeMessage{}
	var order []string
	anonymous := 0

	sc := bufio.NewScanner(f)
	// 초기 64KB, 최대 32MB — 긴 라인(첨부 등)은 필요할 때만 버퍼가 자란다.
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		// 빠른 프리필터: usage 없는 라인은 JSON 파싱 자체를 건너뛴다.
		if !bytes.Contains(line, claudeUsageToken) {
			continue
		}
		var obj struct {
			Type      string `json:"type"`
			Timestamp string `json:"timestamp"`
			RequestID string `json:"requestId"`
			Message   struct {
				ID    string `json:"id"`
				Model string `json:"model"`
				Usage *struct {
					Input      int64 `json:"input_tokens"`
					Output     int64 `json:"output_tokens"`
					CacheWrite int64 `json:"cache_creation_input_tokens"`
					CacheRead  int64 `json:"cache_read_input_tokens"`
				} `json:"usage"`
			} `json:"message"`
		}
		if json.Unmarshal(line, &obj) != nil || obj.Type != "assistant" || obj.Message.Usage == nil {
			continue
		}

		var key string
		if obj.Message.ID != "" {
			key = obj.Message.ID + "|" + obj.RequestID
		} else {
			anonymous++
			key = fmt.Sprintf("__anon__%d", anonymous)
		}
		entry, ok := byMessage[key]
		if !ok {
			entry = &claudeMessage{}
			byMessage[key] = entry
			order = append(order, key)
		}
		u := obj.Message.Usage
		entry.input, entry.output = u.Input, u.Output
		entry.cacheWrite, entry.cacheRead = u.CacheWrite, u.CacheRead
		if mayHaveWindow {
			if ts, err := time.Parse(time.RFC3339, obj.Timestamp); err == nil {
				entry.ts = ts
			}
		}
		if obj.Message.Model != "" {
			entry.model = obj.Message.Model
		}
	}

	e := &claudeFileEntry{
		full:     contribution{models: map[string]int64{}, daily: map[string]TokenUsage{}},
		variants: map[uint64]contribution{},
	}
	effective := contribution{models: map[string]int64{}, daily: map[string]TokenUsage{}}
	var lost []uint64

	for _, key := range order {
		m := byMessage[key]
		isLost := false
		// 익명 키는 파일 로컬이므로 파일 간 dedup 대상에서 제외.
		if !strings.HasPrefix(key, "__anon__") {
			kh := hashKey(key)
			e.keys = append(e.keys, kh)
			if _, dup := seen[kh]; dup {
				isLost = true
				lost = append(lost, kh)
			}
		}
		addClaudeMessage(&e.full, m, windowStart)
		if !isLost {
			addClaudeMessage(&effective, m, windowStart)
		}
	}
	if len(lost) > 0 {
		e.variants[lostDigest(lost)] = effective
	}
	return e, effective
}

// addClaudeMessage — dedup 된 메시지 하나를 기여분에 누적한다.
func addClaudeMessage(c *contribution, m *claudeMessage, windowStart time.Time) {
	total := m.input + m.output + m.cacheWrite + m.cacheRead
	c.usage.Add(TokenUsage{Input: m.input, Output: m.output,
		CacheRead: m.cacheRead, CacheWrite: m.cacheWrite, Total: total})

	// 모델별 누적 — "<synthetic>"(내부 합성 응답)은 제외.
	if total > 0 && m.model != "" && m.model != "<synthetic>" {
		c.models[m.model] += total
	}

	if !m.ts.IsZero() && !m.ts.Before(windowStart) {
		day := DayKey(m.ts)
		u := TokenUsage{Input: m.input, Output: m.output,
			CacheRead: m.cacheRead, CacheWrite: m.cacheWrite, Total: total}
		d := c.daily[day]
		d.Add(u)
		c.daily[day] = d
		// 일자×모델 귀속 — "<synthetic>"(내부 합성 응답)만 제외, 모델 미상은 "" 버킷.
		if m.model != "<synthetic>" {
			c.addDailyModel(day, m.model, u)
		}
	}
}

func dirExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}
