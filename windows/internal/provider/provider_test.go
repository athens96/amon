package provider

import (
	"encoding/base64"
	"fmt"
	"testing"
	"time"
)

func TestCodexWindow(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	metric, ok := codexWindow("세션", map[string]any{
		"used_percent":         "37.5",
		"reset_after_seconds":  float64(600),
		"limit_window_seconds": float64(604800),
	}, now)
	if !ok {
		t.Fatal("expected a metric")
	}
	if metric.RemainingPercent() != 62.5 {
		t.Fatalf("remaining = %v", metric.RemainingPercent())
	}
	if metric.Label != "주간" {
		t.Fatalf("label = %q", metric.Label)
	}
	if !metric.ResetsAt.Equal(now.Add(10 * time.Minute)) {
		t.Fatalf("reset = %v", metric.ResetsAt)
	}
}

func TestClaudeWindow(t *testing.T) {
	metric, ok := claudeWindow("주간", map[string]any{
		"utilization": 120.0,
		"resets_at":   "2026-07-23T12:30:00Z",
	})
	if !ok {
		t.Fatal("expected a metric")
	}
	if metric.UsedPercent != 100 || metric.RemainingPercent() != 0 {
		t.Fatalf("usage = %v, remaining = %v", metric.UsedPercent, metric.RemainingPercent())
	}
}

func TestJWTExpiresAt(t *testing.T) {
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"exp":1893456000}`))
	expires, ok := jwtExpiresAt(fmt.Sprintf("header.%s.signature", payload))
	if !ok || expires.Unix() != 1_893_456_000 {
		t.Fatalf("expires = %v, ok = %v", expires, ok)
	}
}

func TestPlans(t *testing.T) {
	if got := codexPlan("prolite"); got != "Pro 5x" {
		t.Fatalf("codex plan = %q", got)
	}
	if got := claudePlan("max", "default_claude_max_20x"); got != "Max 20x" {
		t.Fatalf("claude plan = %q", got)
	}
}
