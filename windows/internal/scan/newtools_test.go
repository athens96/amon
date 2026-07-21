package scan

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// recentTS — 창 안에 확실히 드는 최근 타임스탬프(UTC RFC3339)와 그 로컬 일자 키.
func recentTS(t *testing.T) (string, string) {
	t.Helper()
	tm := time.Now().Add(-3 * time.Hour).UTC()
	return tm.Format(time.RFC3339), DayKey(tm)
}

func writeFixture(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestScanGemini_ObjectForm(t *testing.T) {
	ResetScanCache()
	ts, day := recentTS(t)
	root := t.TempDir()
	// <root>/hash/chats/session-x.json (오브젝트 형식)
	content := `{"sessionId":"s1","startTime":"` + ts + `","lastUpdated":"` + ts + `","messages":[
  {"type":"user","id":"u1","timestamp":"` + ts + `","content":"hi"},
  {"type":"gemini","id":"a1","timestamp":"` + ts + `","model":"gemini-3-pro","tokens":{"input":1000,"output":50,"cached":200,"thoughts":30}}
]}`
	writeFixture(t, filepath.Join(root, "hash", "chats", "session-x.json"), content)

	s := ScanGemini(root, WindowStart(time.Now()))

	// input=1000, cacheRead=200, output=50+30=80, reasoning=30, cacheWrite=0, total=1280
	if s.Usage.Input != 1000 || s.Usage.Output != 80 || s.Usage.CacheRead != 200 ||
		s.Usage.CacheWrite != 0 || s.Usage.Reasoning != 30 || s.Usage.Total != 1280 {
		t.Fatalf("gemini usage mismatch: %+v", s.Usage)
	}
	if s.Sessions != 1 {
		t.Fatalf("gemini sessions = %d, want 1", s.Sessions)
	}
	if s.Models["gemini-3-pro"] != 1280 {
		t.Fatalf("gemini models = %v, want gemini-3-pro:1280", s.Models)
	}
	if got := s.DailyByModel[day]["gemini-3-pro"]; got.Total != 1280 || got.Input != 1000 {
		t.Fatalf("gemini dailyByModel[%s][gemini-3-pro] = %+v", day, got)
	}
	if s.Daily[day].Total != 1280 {
		t.Fatalf("gemini daily[%s] = %+v", day, s.Daily[day])
	}
}

func TestScanGemini_JSONLLastWins(t *testing.T) {
	ResetScanCache()
	ts, _ := recentTS(t)
	root := t.TempDir()
	// 헤더 라인 + 같은 id 두 번(마지막 값이 이긴다)
	content := `{"sessionId":"s2","startTime":"` + ts + `","lastUpdated":"` + ts + `"}
{"type":"gemini","id":"a1","timestamp":"` + ts + `","model":"gemini-3-pro","tokens":{"input":100,"output":10,"cached":0,"thoughts":0}}
{"type":"gemini","id":"a1","timestamp":"` + ts + `","model":"gemini-3-pro","tokens":{"input":500,"output":40,"cached":0,"thoughts":5}}
`
	writeFixture(t, filepath.Join(root, "h", "chats", "session-y.jsonl"), content)

	s := ScanGemini(root, WindowStart(time.Now()))

	// last-wins: input=500, output=40+5=45, reasoning=5, total=545
	if s.Usage.Total != 545 || s.Usage.Input != 500 || s.Usage.Output != 45 || s.Usage.Reasoning != 5 {
		t.Fatalf("gemini last-wins mismatch: %+v", s.Usage)
	}
	if s.Sessions != 1 {
		t.Fatalf("gemini sessions = %d, want 1", s.Sessions)
	}
}

func TestScanGemini_CumulativeDeltas(t *testing.T) {
	ResetScanCache()
	ts, day := recentTS(t)
	root := t.TempDir()
	// 다중턴: tokens.input/cached 는 누적 컨텍스트값 → 증분만 소비 (user 메시지는 prev 불변).
	content := `{"sessionId":"sess-ctx","startTime":"` + ts + `","lastUpdated":"` + ts + `","messages":[
  {"type":"user","timestamp":"` + ts + `","content":[{"text":"q1"}]},
  {"type":"gemini","timestamp":"` + ts + `","content":"a1","model":"gemini-3-pro","tokens":{"input":10000,"output":50,"cached":0}},
  {"type":"user","timestamp":"` + ts + `","content":[{"text":"q2"}]},
  {"type":"gemini","timestamp":"` + ts + `","content":"a2","model":"gemini-3-pro","tokens":{"input":22000,"output":80,"cached":3000}},
  {"type":"gemini","timestamp":"` + ts + `","content":"a3","model":"gemini-3-pro","tokens":{"input":60000,"output":120,"cached":0}}
]}`
	writeFixture(t, filepath.Join(root, "h", "chats", "session-d.json"), content)

	s := ScanGemini(root, WindowStart(time.Now()))

	// a1: in 10000, cache 0, out 50   (prev 0/0 → 10000/0)
	// a2: in 12000, cache 3000, out 80 (prev 10000/0 → 22000/3000)
	// a3: in 38000, cache 0 (0-3000<0→0), out 120 (prev 22000/3000 → 60000/0)
	// sum: input 60000, output 250, cacheRead 3000, total 63250
	if s.Usage.Input != 60000 || s.Usage.Output != 250 || s.Usage.CacheRead != 3000 || s.Usage.Total != 63250 {
		t.Fatalf("gemini cumulative-delta mismatch: %+v", s.Usage)
	}
	if s.Models["gemini-3-pro"] != 63250 {
		t.Fatalf("gemini models = %v, want gemini-3-pro:63250", s.Models)
	}
	if got := s.DailyByModel[day]["gemini-3-pro"]; got.Input != 60000 || got.Total != 63250 {
		t.Fatalf("gemini dailyByModel[%s] = %+v", day, got)
	}
}

func TestScanGemini_CounterResetClampsToCumulative(t *testing.T) {
	ResetScanCache()
	ts, _ := recentTS(t)
	root := t.TempDir()
	// 카운터 리셋: input 이 감소하면 델타를 음수로 두지 않고 그 값 자체를 소비로 본다.
	content := `{"sessionId":"sess-reset","startTime":"` + ts + `","lastUpdated":"` + ts + `","messages":[
  {"type":"gemini","timestamp":"` + ts + `","content":"a1","model":"gemini-3-pro","tokens":{"input":10000,"output":50,"cached":0}},
  {"type":"gemini","timestamp":"` + ts + `","content":"a2","model":"gemini-3-pro","tokens":{"input":25000,"output":80,"cached":0}},
  {"type":"gemini","timestamp":"` + ts + `","content":"a3","model":"gemini-3-pro","tokens":{"input":5000,"output":120,"cached":0}}
]}`
	writeFixture(t, filepath.Join(root, "h", "chats", "session-r.json"), content)

	s := ScanGemini(root, WindowStart(time.Now()))

	// deltas: 10000, 15000, 5000(리셋: 5000-25000<0 → 5000). output 50+80+120=250.
	// sum: input 30000, output 250, cacheRead 0, total 30250
	if s.Usage.Input != 30000 || s.Usage.Output != 250 || s.Usage.CacheRead != 0 || s.Usage.Total != 30250 {
		t.Fatalf("gemini reset-clamp mismatch: %+v", s.Usage)
	}
}

func TestScanQwen_Mapping(t *testing.T) {
	ResetScanCache()
	ts, day := recentTS(t)
	root := t.TempDir()
	// projects/<proj>/chats/<stem>.jsonl
	content := `{"type":"user","sessionId":"q1","timestamp":"` + ts + `","message":{"role":"user","parts":[{"text":"calc"}]}}
{"type":"assistant","timestamp":"` + ts + `","model":"qwen3-coder","message":{"role":"model","parts":[{"text":"done"}]},"usageMetadata":{"promptTokenCount":18009,"candidatesTokenCount":47,"thoughtsTokenCount":36,"cachedContentTokenCount":12}}
`
	writeFixture(t, filepath.Join(root, "proj", "chats", "sess.jsonl"), content)

	s := ScanQwen(root, WindowStart(time.Now()))

	// cacheRead=12, input=18009-12=17997, output=47+36=83, reasoning=36, total=18092
	if s.Usage.Input != 17997 || s.Usage.Output != 83 || s.Usage.CacheRead != 12 ||
		s.Usage.Reasoning != 36 || s.Usage.Total != 18092 {
		t.Fatalf("qwen usage mismatch: %+v", s.Usage)
	}
	if s.Sessions != 1 {
		t.Fatalf("qwen sessions = %d, want 1", s.Sessions)
	}
	if s.Models["qwen3-coder"] != 18092 {
		t.Fatalf("qwen models = %v", s.Models)
	}
	if got := s.DailyByModel[day]["qwen3-coder"]; got.Total != 18092 {
		t.Fatalf("qwen dailyByModel[%s] = %+v", day, got)
	}
}

func TestScanQwen_SumsPerLine(t *testing.T) {
	ResetScanCache()
	ts, _ := recentTS(t)
	root := t.TempDir()
	// 턴 내 tool-call 반복 라인마다 usageMetadata → 라인 단위 합산
	content := `{"type":"assistant","sessionId":"q2","timestamp":"` + ts + `","model":"qwen","message":{"role":"model","parts":[{"functionCall":{"id":"c1","name":"read"}}]},"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":10,"cachedContentTokenCount":0}}
{"type":"assistant","timestamp":"` + ts + `","model":"qwen","message":{"role":"model","parts":[{"text":"done"}]},"usageMetadata":{"promptTokenCount":200,"candidatesTokenCount":20,"cachedContentTokenCount":50}}
`
	writeFixture(t, filepath.Join(root, "p", "chats", "s.jsonl"), content)

	s := ScanQwen(root, WindowStart(time.Now()))

	// line1: input 100, out 10, cache 0, total 110
	// line2: input 200-50=150, out 20, cache 50, total 220
	// sum:   input 250, out 30, cache 50, total 330
	if s.Usage.Input != 250 || s.Usage.Output != 30 || s.Usage.CacheRead != 50 || s.Usage.Total != 330 {
		t.Fatalf("qwen sum mismatch: %+v", s.Usage)
	}
}

func TestScanCopilot_ShutdownMapping(t *testing.T) {
	ResetScanCache()
	ts, day := recentTS(t)
	root := t.TempDir()
	stateDir := filepath.Join(root, "session-state")
	content := `{"type":"session.start","data":{"sessionId":"uuid1"},"timestamp":"` + ts + `"}
{"type":"session.shutdown","data":{"modelMetrics":{"claude-sonnet-4.6":{"usage":{"inputTokens":931647,"outputTokens":7150,"cacheReadTokens":873267,"cacheWriteTokens":51438,"reasoningTokens":432}}}},"timestamp":"` + ts + `"}
`
	writeFixture(t, filepath.Join(stateDir, "uuid1.jsonl"), content)

	s := ScanCopilot(stateDir, WindowStart(time.Now()))

	// freshInput=931647-873267-51438=6942, total=6942+7150+873267+51438=938797
	if s.Usage.Input != 6942 || s.Usage.Output != 7150 || s.Usage.CacheRead != 873267 ||
		s.Usage.CacheWrite != 51438 || s.Usage.Reasoning != 432 || s.Usage.Total != 938797 {
		t.Fatalf("copilot usage mismatch: %+v", s.Usage)
	}
	if s.Sessions != 1 {
		t.Fatalf("copilot sessions = %d, want 1", s.Sessions)
	}
	// 모델 정규화: claude-sonnet-4.6 → claude-sonnet-4-6
	if s.Models["claude-sonnet-4-6"] != 938797 {
		t.Fatalf("copilot models = %v", s.Models)
	}
	if got := s.DailyByModel[day]["claude-sonnet-4-6"]; got.Total != 938797 {
		t.Fatalf("copilot dailyByModel[%s] = %+v", day, got)
	}
}

func TestScanCopilot_DirWinsOverFlat(t *testing.T) {
	ResetScanCache()
	ts, _ := recentTS(t)
	root := t.TempDir()
	stateDir := filepath.Join(root, "session-state")
	// 같은 uuid 의 플랫(구) + 디렉토리(신) — 디렉토리가 이겨야 한다.
	flat := `{"type":"session.shutdown","data":{"modelMetrics":{"claude-x":{"usage":{"inputTokens":100,"outputTokens":10,"cacheReadTokens":0,"cacheWriteTokens":0}}}},"timestamp":"` + ts + `"}
`
	dir := `{"type":"session.shutdown","data":{"modelMetrics":{"claude-x":{"usage":{"inputTokens":500,"outputTokens":50,"cacheReadTokens":0,"cacheWriteTokens":0}}}},"timestamp":"` + ts + `"}
`
	writeFixture(t, filepath.Join(stateDir, "uuidD.jsonl"), flat)
	writeFixture(t, filepath.Join(stateDir, "uuidD", "events.jsonl"), dir)

	s := ScanCopilot(stateDir, WindowStart(time.Now()))

	// 디렉토리 값(500/50)만, 세션은 1개(중복 카운트 금지)
	if s.Usage.Input != 500 || s.Usage.Output != 50 || s.Usage.Total != 550 {
		t.Fatalf("copilot dir-wins mismatch: %+v", s.Usage)
	}
	if s.Sessions != 1 {
		t.Fatalf("copilot sessions = %d, want 1", s.Sessions)
	}
}

// TestNewScanners_WarmEqualsCold — 지문 캐시를 거친 두 번째 스캔 결과가 콜드 스캔과
// 정확히 같아야 한다(기존 claude/codex 캐시 불변식과 동일). 새 3종에도 적용.
func TestNewScanners_WarmEqualsCold(t *testing.T) {
	ts, _ := recentTS(t)

	geminiRoot := t.TempDir()
	writeFixture(t, filepath.Join(geminiRoot, "h", "chats", "session-a.jsonl"),
		`{"sessionId":"g","startTime":"`+ts+`","lastUpdated":"`+ts+`"}
{"type":"gemini","id":"a1","timestamp":"`+ts+`","model":"gemini-3-pro","tokens":{"input":300,"output":20,"cached":10,"thoughts":5}}
`)
	qwenRoot := t.TempDir()
	writeFixture(t, filepath.Join(qwenRoot, "p", "chats", "s.jsonl"),
		`{"type":"assistant","sessionId":"q","timestamp":"`+ts+`","model":"qwen","message":{"role":"model","parts":[{"text":"x"}]},"usageMetadata":{"promptTokenCount":500,"candidatesTokenCount":30,"cachedContentTokenCount":40}}
`)
	copilotRoot := t.TempDir()
	stateDir := filepath.Join(copilotRoot, "session-state")
	writeFixture(t, filepath.Join(stateDir, "u1.jsonl"),
		`{"type":"session.shutdown","data":{"modelMetrics":{"gpt-5.5":{"usage":{"inputTokens":400,"outputTokens":40,"cacheReadTokens":100,"cacheWriteTokens":20}}}},"timestamp":"`+ts+`"}
`)

	cases := []struct {
		name string
		scan func() ToolSummary
	}{
		{"gemini", func() ToolSummary { return ScanGemini(geminiRoot, WindowStart(time.Now())) }},
		{"qwen", func() ToolSummary { return ScanQwen(qwenRoot, WindowStart(time.Now())) }},
		{"copilot", func() ToolSummary { return ScanCopilot(stateDir, WindowStart(time.Now())) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ResetScanCache()
			cold := c.scan() // 콜드
			warm := c.scan() // 워밍(캐시 적중)
			if !reflect.DeepEqual(cold, warm) {
				t.Fatalf("%s warm != cold\ncold=%+v\nwarm=%+v", c.name, cold, warm)
			}
		})
	}
}

func TestScanCopilot_MultipleShutdownsSum(t *testing.T) {
	ResetScanCache()
	ts, _ := recentTS(t)
	root := t.TempDir()
	stateDir := filepath.Join(root, "session-state")
	// 재시작으로 한 파일에 shutdown 두 번 → 합산
	content := `{"type":"session.shutdown","data":{"modelMetrics":{"gpt-5.5":{"usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":60,"cacheWriteTokens":10}}}},"timestamp":"` + ts + `"}
{"type":"session.shutdown","data":{"modelMetrics":{"gpt-5.5":{"usage":{"inputTokens":300,"outputTokens":80,"cacheReadTokens":250,"cacheWriteTokens":20}}}},"timestamp":"` + ts + `"}
`
	writeFixture(t, filepath.Join(stateDir, "uuidM.jsonl"), content)

	s := ScanCopilot(stateDir, WindowStart(time.Now()))

	// s1: fresh=100-60-10=30, total=30+50+60+10=150
	// s2: fresh=300-250-20=30, total=30+80+250+20=380
	// sum: input 60, output 130, cacheRead 310, cacheWrite 30, total 530
	if s.Usage.Input != 60 || s.Usage.Output != 130 || s.Usage.CacheRead != 310 ||
		s.Usage.CacheWrite != 30 || s.Usage.Total != 530 {
		t.Fatalf("copilot multi-shutdown mismatch: %+v", s.Usage)
	}
	// gpt- 모델은 정규화하지 않음(점 유지)
	if s.Models["gpt-5.5"] != 530 {
		t.Fatalf("copilot gpt model = %v", s.Models)
	}
}
