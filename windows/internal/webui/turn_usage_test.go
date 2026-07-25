package webui

import (
	"strings"
	"testing"

	"github.com/athens96/amon/windows/internal/session"
)

func TestTurnUsageBadgeAndTooltip(t *testing.T) {
	u := session.TurnUsage{
		Input: 1200, Output: 300, CacheRead: 4000, CacheWrite: 50,
		Reasoning: 125, Total: 5550,
	}
	if got := usageBadge(u); got != "in 5250 · out 300" {
		t.Fatalf("badge = %q", got)
	}
	tip := usageTip(u)
	for _, want := range []string{"입력 1,200", "캐시 읽기 4,000", "캐시 쓰기 50", "추론 125", "총 5,550"} {
		if !strings.Contains(tip, want) {
			t.Fatalf("tooltip missing %q: %s", want, tip)
		}
	}
	if !strings.Contains(detailTmpl.Tree.Root.String(), ".UsageTip") {
		t.Fatal("detail template does not render turn usage tooltip")
	}
}

func TestCSSColorTokens(t *testing.T) {
	for _, token := range []string{
		"--accent:", "--text:", "--muted:", "--line:", "--bg:", "--surface:", "--soft:",
		"--card-mint:", "--card-lavender:", "--card-sky:", "--card-sunset:",
		"--card-pale-blue:", "--card-ocean:", "--card-ice:",
	} {
		if !strings.Contains(baseCSS, token) {
			t.Errorf("missing CSS token %s", token)
		}
	}
	if !strings.Contains(baseCSS, "prefers-color-scheme: dark") {
		t.Fatal("dark color token block missing")
	}
}
