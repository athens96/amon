package webui

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/athens96/amon/windows/internal/scan"
	"github.com/athens96/amon/windows/internal/session"
)

// 목록은 요약을, 상세는 클릭 시점에 원본 로그를 읽어 전문을 보여줘야 한다.
func TestListAndLazyDetail(t *testing.T) {
	dir := t.TempDir()

	// 원본 로그 — 요약(첫 줄)보다 긴 본문.
	transcript := filepath.Join(dir, "proj", "sess-1.jsonl")
	if err := os.MkdirAll(filepath.Dir(transcript), 0o755); err != nil {
		t.Fatal(err)
	}
	lines := `{"type":"user","timestamp":"2026-07-14T01:00:00Z","promptSource":"typed","cwd":"/tmp/demo","message":{"content":[{"type":"text","text":"요청 첫 줄\n요청 둘째 줄"}]}}
{"type":"assistant","timestamp":"2026-07-14T01:00:05Z","requestId":"r1","message":{"id":"m1","content":[{"type":"text","text":"응답 첫 줄\n응답 둘째 줄 전문"}]}}
`
	if err := os.WriteFile(transcript, []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}

	store := &session.Store{Path: filepath.Join(dir, "sessions.jsonl")}
	store.Upsert([]session.Record{{
		Provider: "claude", SessionID: "sess-1", ProjectLabel: "demo",
		StartedAt: time.Now().Add(-time.Hour), EndedAt: time.Now(),
		Prompts: []string{"요청 첫 줄"}, PromptCount: 1,
		LastResult: "응답 첫 줄", TotalTokens: 42,
		SourcePath: transcript,
	}})

	srv, err := start(store, dir, "")
	if err != nil {
		t.Fatal(err)
	}
	srv.UpdateSummaries([]scan.ToolSummary{{
		DisplayName: "Claude Code",
		Today:       scan.TokenUsage{Input: 700, Output: 300, Total: 1000},
		Usage:       scan.TokenUsage{Total: 4200},
		Sessions:    3,
	}})

	get := func(url string) string {
		resp, err := http.Get(url)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("GET %s → %d", url, resp.StatusCode)
		}
		body, _ := io.ReadAll(resp.Body)
		return string(body)
	}

	list := get(srv.URL())
	if !strings.Contains(list, "demo") || !strings.Contains(list, "요청 첫 줄") {
		t.Fatalf("목록에 세션이 없음: %s", list)
	}
	for _, want := range []string{"오늘 사용량", "Claude Code", "4200", "LIVE"} {
		if !strings.Contains(list, want) {
			t.Fatalf("대시보드 표시 누락(%q): %s", want, list)
		}
	}
	if strings.Contains(list, "요청 둘째 줄") {
		t.Fatal("목록이 전문을 미리 들고 있음 — 요약만 있어야 한다")
	}

	detail := get(srv.URL() + "session?id=claude:sess-1")
	for _, want := range []string{"요청 첫 줄", "요청 둘째 줄", "응답 둘째 줄 전문"} {
		if !strings.Contains(detail, want) {
			t.Fatalf("상세에 전문 누락(%q): %s", want, detail)
		}
	}

	// 토큰 없는 경로는 차단 — 같은 기계의 다른 프로세스가 URL 을 추측하지 못하게.
	resp, err := http.Get("http://" + srv.addr + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == 200 {
		t.Fatal("토큰 없는 요청이 통과함")
	}
}
