package scan

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

// TestCodexDailyScaledToSessionTotal — Σ(턴 단건)이 최종 누적을 초과하는 rollout
// (중단/재시도 턴이 누적 카운터에 미반영되는 실측 케이스)은 턴 기여분을 비례
// 스케일링해 Σ(일자 버킷) == 세션 누적(권위값)으로 정합시킨다.
func TestCodexDailyScaledToSessionTotal(t *testing.T) {
	root := t.TempDir()
	now := time.Now()
	ws := WindowStart(now)
	day := DayKey(now)

	// last=100 인 턴 두 개, 최종 누적은 150 — Σ턴 200 > 최종 150 (factor 0.75).
	line := func(lastIn, cumIn int64) string {
		return fmt.Sprintf(`{"timestamp":%q,"payload":{"type":"token_count","info":{`+
			`"total_token_usage":{"input_tokens":%d,"cached_input_tokens":0,`+
			`"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":%d},`+
			`"last_token_usage":{"input_tokens":%d,"cached_input_tokens":0,`+
			`"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":%d}}}}`,
			now.Format(time.RFC3339), cumIn, cumIn, lastIn, lastIn)
	}
	writeLines(t, filepath.Join(root, "2026", "07", "07", "rollout-scale.jsonl"),
		codexTurnContextLine(now, "gpt-5.5"),
		line(100, 100),
		line(100, 150),
	)

	old := codexOrcaSessions
	codexOrcaSessions = ""
	defer func() { codexOrcaSessions = old }()

	ResetScanCache()
	s := ScanCodex(root, ws)
	if s.Usage.Total != 150 {
		t.Fatalf("session total = %d, want 150 (최종 누적이 권위값)", s.Usage.Total)
	}
	if got := s.Daily[day].Total; got != 150 {
		t.Fatalf("daily total = %d, want 150 (Σ턴 200 을 0.75 스케일)", got)
	}
	if got := s.DailyByModel[day]["gpt-5.5"].Total; got != 150 {
		t.Fatalf("dailyByModel total = %d, want 150", got)
	}

	// Σ턴 == 최종 누적이면 스케일 없이 그대로 — 기존 동작 회귀 방지.
	writeLines(t, filepath.Join(root, "2026", "07", "07", "rollout-exact.jsonl"),
		codexTurnContextLine(now, "gpt-5.5"),
		line(80, 80),
	)
	ResetScanCache()
	s2 := ScanCodex(root, ws)
	if got := s2.Daily[day].Total; got != 150+80 {
		t.Fatalf("daily total = %d, want 230", got)
	}
}
