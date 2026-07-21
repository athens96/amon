package scan

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// 캐시의 핵심 불변식: 워밍 캐시 스캔 결과 == 콜드 스캔 결과.
// 어떤 파일 변화(추가·수정·삭제·resume 겹침)가 있어도 캐시를 거친 요약은
// 캐시 없이 처음부터 스캔한 요약과 정확히 같아야 한다.

func claudeLine(id, reqID, model string, in, out, cw, cr int64, ts time.Time) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":%q,"requestId":%q,`+
		`"message":{"id":%q,"model":%q,"usage":{"input_tokens":%d,"output_tokens":%d,`+
		`"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d}}}`,
		ts.Format(time.RFC3339), reqID, id, model, in, out, cw, cr)
}

func anonClaudeLine(model string, in, out int64, ts time.Time) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":%q,`+
		`"message":{"model":%q,"usage":{"input_tokens":%d,"output_tokens":%d,`+
		`"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}`,
		ts.Format(time.RFC3339), model, in, out)
}

func writeLines(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	var data []byte
	for _, l := range lines {
		data = append(data, l...)
		data = append(data, '\n')
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// coldScanClaude — 캐시를 비우고 스캔 (기준값).
func coldScanClaude(root string, ws time.Time) ToolSummary {
	ResetScanCache()
	return ScanClaude(root, ws)
}

func requireEqualSummary(t *testing.T, got, want ToolSummary, label string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: 워밍 캐시 결과가 콜드 스캔과 다름\n got: %+v\nwant: %+v", label, got, want)
	}
}

func TestClaudeWarmEqualsCold(t *testing.T) {
	root := t.TempDir()
	ws := WindowStart(time.Now())
	now := time.Now()

	// a.jsonl: k1, k2 (+같은 k1 재등장 — last-wins), 익명 1건
	writeLines(t, filepath.Join(root, "p1", "a.jsonl"),
		claudeLine("k1", "r1", "model-a", 5, 5, 0, 0, now),
		claudeLine("k1", "r1", "model-a", 10, 1, 100, 1000, now), // last-wins 갱신
		claudeLine("k2", "r2", "model-a", 20, 2, 0, 0, now),
		anonClaudeLine("model-a", 3, 3, now),
	)
	// b.jsonl: k2 재등장(--resume 복사 — a 가 이김) + k3, 창 밖 타임스탬프 1건
	writeLines(t, filepath.Join(root, "p2", "b.jsonl"),
		claudeLine("k2", "r2", "model-a", 20, 2, 0, 0, now),
		claudeLine("k3", "r3", "model-b", 30, 3, 0, 0, now),
		claudeLine("k4", "r4", "model-b", 7, 7, 0, 0, now.AddDate(0, 0, -30)), // 창 밖
	)

	cold := coldScanClaude(root, ws)
	warm := ScanClaude(root, ws) // 두 번째 — 전 파일 캐시 적중
	requireEqualSummary(t, warm, cold, "무변경 재스캔")

	// dedup 검증: k2 는 한 번만 — input = 10+20+3+30+7
	if cold.Usage.Input != 70 {
		t.Fatalf("input 합계 = %d, want 70 (k2 중복 제거)", cold.Usage.Input)
	}
	if cold.Sessions != 2 {
		t.Fatalf("sessions = %d, want 2", cold.Sessions)
	}
}

func TestClaudeMutationInvalidates(t *testing.T) {
	root := t.TempDir()
	ws := WindowStart(time.Now())
	now := time.Now()
	a := filepath.Join(root, "a.jsonl")
	b := filepath.Join(root, "b.jsonl")

	writeLines(t, a, claudeLine("k1", "r1", "m", 10, 1, 0, 0, now))
	writeLines(t, b, claudeLine("k1", "r1", "m", 10, 1, 0, 0, now), // a 에 빼앗김
		claudeLine("k2", "r2", "m", 20, 2, 0, 0, now))

	_ = coldScanClaude(root, ws)
	_ = ScanClaude(root, ws) // 변형(variant) 경로 워밍

	// b 에 새 메시지 추가 → b 만 재파싱되어야 하며 결과는 콜드와 동일.
	writeLines(t, b, claudeLine("k1", "r1", "m", 10, 1, 0, 0, now),
		claudeLine("k2", "r2", "m", 20, 2, 0, 0, now),
		claudeLine("k3", "r3", "m", 40, 4, 0, 0, now))
	warm := ScanClaude(root, ws)
	cold := coldScanClaude(root, ws)
	requireEqualSummary(t, warm, cold, "파일 수정 후")
	if cold.Usage.Input != 70 { // 10 + 20 + 40 (k1 은 a 가 이김)
		t.Fatalf("input = %d, want 70", cold.Usage.Input)
	}
}

func TestClaudeDeletionRestoresDupKey(t *testing.T) {
	root := t.TempDir()
	ws := WindowStart(time.Now())
	now := time.Now()
	a := filepath.Join(root, "a.jsonl")
	b := filepath.Join(root, "b.jsonl")

	writeLines(t, a, claudeLine("k1", "r1", "m", 10, 1, 0, 0, now))
	writeLines(t, b, claudeLine("k1", "r1", "m", 10, 1, 0, 0, now),
		claudeLine("k2", "r2", "m", 20, 2, 0, 0, now))

	first := coldScanClaude(root, ws)
	if first.Usage.Input != 30 { // k1(a) + k2(b)
		t.Fatalf("input = %d, want 30", first.Usage.Input)
	}

	// a 삭제 → k1 은 이제 b 소유. 워밍 캐시로도 콜드와 같아야 한다.
	if err := os.Remove(a); err != nil {
		t.Fatal(err)
	}
	warm := ScanClaude(root, ws)
	cold := coldScanClaude(root, ws)
	requireEqualSummary(t, warm, cold, "파일 삭제 후")
	if warm.Usage.Input != 30 { // k1(b) + k2(b)
		t.Fatalf("input = %d, want 30 (k1 을 b 가 회수)", warm.Usage.Input)
	}
	if warm.Sessions != 1 {
		t.Fatalf("sessions = %d, want 1", warm.Sessions)
	}
}

func TestClaudeOldFileOutsideWindow(t *testing.T) {
	root := t.TempDir()
	ws := WindowStart(time.Now())
	old := time.Now().AddDate(0, 0, -30)
	p := filepath.Join(root, "old.jsonl")

	writeLines(t, p, claudeLine("k1", "r1", "m", 10, 1, 0, 0, old))
	if err := os.Chtimes(p, old, old); err != nil { // mtime 도 창 밖으로
		t.Fatal(err)
	}

	cold := coldScanClaude(root, ws)
	warm := ScanClaude(root, ws)
	requireEqualSummary(t, warm, cold, "창 밖 파일")
	if len(cold.Daily) != 0 {
		t.Fatalf("창 밖 파일이 daily 에 기여: %+v", cold.Daily)
	}
	if cold.Usage.Input != 10 { // 누적 합계엔 포함
		t.Fatalf("input = %d, want 10", cold.Usage.Input)
	}
}

// ── Codex ────────────────────────────────────────────────────

func codexTokenLine(ts time.Time, totalIn, totalCached, totalOut, lastIn, lastOut int64) string {
	return fmt.Sprintf(`{"timestamp":%q,"payload":{"type":"token_count","info":{`+
		`"total_token_usage":{"input_tokens":%d,"cached_input_tokens":%d,"output_tokens":%d,`+
		`"reasoning_output_tokens":0,"total_tokens":%d},`+
		`"last_token_usage":{"input_tokens":%d,"cached_input_tokens":0,"output_tokens":%d,`+
		`"reasoning_output_tokens":0,"total_tokens":%d}}}}`,
		ts.Format(time.RFC3339), totalIn, totalCached, totalOut, totalIn+totalOut,
		lastIn, lastOut, lastIn+lastOut)
}

func codexTurnContextLine(ts time.Time, model string) string {
	return fmt.Sprintf(`{"timestamp":%q,"payload":{"type":"turn_context","model":%q}}`,
		ts.Format(time.RFC3339), model)
}

func TestCodexWarmEqualsCold(t *testing.T) {
	root := t.TempDir()
	ws := WindowStart(time.Now())
	now := time.Now()

	writeLines(t, filepath.Join(root, "2026", "07", "07", "rollout-1.jsonl"),
		codexTurnContextLine(now, "gpt-5.5"),
		codexTokenLine(now, 50, 10, 5, 50, 5),
		codexTokenLine(now, 100, 20, 10, 50, 5), // 마지막 스냅샷이 세션 누적
	)
	writeLines(t, filepath.Join(root, "2026", "07", "07", "rollout-2.jsonl"),
		`{"timestamp":"x","payload":{"type":"other"}}`, // token_count 없음
	)

	ResetScanCache()
	cold := ScanCodex(root, ws)
	warm := ScanCodex(root, ws)
	requireEqualSummary(t, warm, cold, "무변경 재스캔")

	if cold.Sessions != 1 || cold.Usage.Total != 110 || cold.Usage.CacheRead != 20 {
		t.Fatalf("codex 요약 이상: %+v", cold.Usage)
	}
	if cold.Models["gpt-5.5"] != 110 {
		t.Fatalf("모델 귀속 이상: %+v", cold.Models)
	}

	// 파일 수정 → 캐시 무효화 확인.
	writeLines(t, filepath.Join(root, "2026", "07", "07", "rollout-2.jsonl"),
		codexTokenLine(now, 30, 0, 3, 30, 3),
	)
	warm2 := ScanCodex(root, ws)
	ResetScanCache()
	cold2 := ScanCodex(root, ws)
	requireEqualSummary(t, warm2, cold2, "파일 수정 후")
	if cold2.Sessions != 2 {
		t.Fatalf("sessions = %d, want 2", cold2.Sessions)
	}
}

// TestCodexMergesRootsDedupBySession — 설정 경로 + Orca 폴백을 함께 읽되, 같은
// rollout 파일명(세션)이 두 root 에 있으면(격리 홈이 하드링크/복제로 공유) 한 번만 센다.
func TestCodexMergesRootsDedupBySession(t *testing.T) {
	ws := WindowStart(time.Now())
	now := time.Now()
	primary := t.TempDir()
	orca := t.TempDir()

	// primary: 세션 A + 공유 세션 S
	writeLines(t, filepath.Join(primary, "2026", "07", "07", "rollout-A.jsonl"),
		codexTurnContextLine(now, "gpt-5.5"), codexTokenLine(now, 100, 0, 10, 100, 10))
	writeLines(t, filepath.Join(primary, "2026", "07", "07", "rollout-S.jsonl"),
		codexTurnContextLine(now, "gpt-5.5"), codexTokenLine(now, 200, 0, 20, 200, 20))
	// orca: 같은 basename 의 공유 세션 S(값 달라도 스킵) + 고유 세션 B
	writeLines(t, filepath.Join(orca, "2026", "07", "07", "rollout-S.jsonl"),
		codexTurnContextLine(now, "gpt-5.5"), codexTokenLine(now, 999, 0, 99, 999, 99))
	writeLines(t, filepath.Join(orca, "2026", "07", "07", "rollout-B.jsonl"),
		codexTurnContextLine(now, "gpt-5.5"), codexTokenLine(now, 300, 0, 30, 300, 30))

	old := codexOrcaSessions
	codexOrcaSessions = orca
	defer func() { codexOrcaSessions = old }()

	ResetScanCache()
	s := ScanCodex(primary, ws)

	// A(110) + S(220, primary 먼저) + B(330) = 660, orca 의 S 사본(1098) 스킵
	if s.Sessions != 3 {
		t.Fatalf("sessions = %d, want 3 (공유 세션 중복 제외)", s.Sessions)
	}
	if s.Usage.Total != 660 {
		t.Fatalf("total = %d, want 660 (A110+S220+B330, orca S 스킵)", s.Usage.Total)
	}
	if s.Models["gpt-5.5"] != 660 {
		t.Fatalf("models gpt-5.5 = %d, want 660", s.Models["gpt-5.5"])
	}
}

// TestCodexRootsDedupSamePath — 폴백 경로가 설정 경로와 같으면(맥에서 CODEX_HOME 로
// primary==orca 가 되는 상황) EvalSymlinks 정규화 dedup 으로 한 번만 walk 한다.
func TestCodexRootsDedupSamePath(t *testing.T) {
	ws := WindowStart(time.Now())
	now := time.Now()
	primary := t.TempDir()
	writeLines(t, filepath.Join(primary, "2026", "07", "07", "rollout-A.jsonl"),
		codexTurnContextLine(now, "gpt-5.5"), codexTokenLine(now, 100, 0, 10, 100, 10))

	old := codexOrcaSessions
	codexOrcaSessions = primary
	defer func() { codexOrcaSessions = old }()

	ResetScanCache()
	s := ScanCodex(primary, ws)
	if s.Sessions != 1 || s.Usage.Total != 110 {
		t.Fatalf("same-path dedup: sessions=%d total=%d, want 1/110", s.Sessions, s.Usage.Total)
	}
}
