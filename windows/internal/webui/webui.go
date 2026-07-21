// Package webui — 세션 기록 열람용 로컬 HTTP 서버.
//
// macOS 는 팝오버 화면(SessionHistoryView/SessionTranscriptView)이 있지만
// Windows 트레이(fyne systray)는 메뉴만 그릴 수 있고 창이 없다. 풀 GUI/webview
// 는 cgo 가 필요해 "맥에서 크로스컴파일" 제약을 깨므로, 기본 브라우저에 여는
// 로컬 페이지로 같은 기능을 제공한다: 세션 목록 → 행 클릭 → 요청·응답 전문.
//
// 전문은 맥과 같은 lazy 규칙 — 상세 요청이 들어온 순간에만 원본 로그를 읽고,
// 결과는 저장하지 않는다. 서버는 127.0.0.1 에만 바인드하고 실행마다 새로 뽑는
// 랜덤 토큰을 경로에 넣어 같은 기계의 다른 사용자·프로세스가 URL 을 추측해
// 로그를 읽는 것을 막는다.
package webui

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/athens96/amon/windows/internal/scan"
	"github.com/athens96/amon/windows/internal/session"
)

// Server — 세션 기록 웹 UI. Start 로 만들고 URL() 을 브라우저로 연다.
type Server struct {
	store      *session.Store
	claudeRoot string
	codexRoot  string
	token      string
	addr       string
	dataMu     sync.RWMutex
	summaries  []scan.ToolSummary
	paths      scan.Paths
}

var (
	mu     sync.Mutex
	shared *Server // 트레이 메뉴에서 재클릭 시 재사용 — 포트를 매번 새로 열지 않는다
)

// Ensure — 서버가 없으면 띄우고, 있으면 그대로 돌려준다.
func Ensure(store *session.Store, claudeRoot, codexRoot string) (*Server, error) {
	mu.Lock()
	defer mu.Unlock()
	if shared != nil {
		return shared, nil
	}
	s, err := start(store, claudeRoot, codexRoot)
	if err != nil {
		return nil, err
	}
	shared = s
	return s, nil
}

func start(store *session.Store, claudeRoot, codexRoot string) (*Server, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return nil, err
	}
	s := &Server{
		store:      store,
		claudeRoot: claudeRoot,
		codexRoot:  codexRoot,
		token:      hex.EncodeToString(buf),
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	s.addr = ln.Addr().String()

	prefix := "/" + s.token
	mux := http.NewServeMux()
	mux.HandleFunc(prefix+"/", s.handleList)
	mux.HandleFunc(prefix+"/session", s.handleDetail)
	go func() { _ = http.Serve(ln, mux) }()
	return s, nil
}

// URL — 목록 페이지 주소.
func (s *Server) URL() string { return fmt.Sprintf("http://%s/%s/", s.addr, s.token) }

// UpdateSummaries replaces the usage snapshot rendered on the dashboard.
func (s *Server) UpdateSummaries(summaries []scan.ToolSummary) {
	s.dataMu.Lock()
	s.summaries = append([]scan.ToolSummary(nil), summaries...)
	s.dataMu.Unlock()
}

// SetPaths enables on-demand rescanning whenever the dashboard is refreshed.
func (s *Server) SetPaths(paths scan.Paths) {
	s.dataMu.Lock()
	s.paths = paths.WithDefaults()
	s.dataMu.Unlock()
}

func (s *Server) usageSnapshot() []scan.ToolSummary {
	s.dataMu.RLock()
	defer s.dataMu.RUnlock()
	return append([]scan.ToolSummary(nil), s.summaries...)
}

func (s *Server) refreshLocalData() {
	s.dataMu.RLock()
	paths := s.paths
	s.dataMu.RUnlock()
	if paths.Claude == "" && paths.Codex == "" {
		return
	}
	s.UpdateSummaries(scan.ScanAll(paths))
	cache := session.LoadFileCache("")
	fresh := session.ScanClaude(paths.Claude, cache)
	fresh = append(fresh, session.ScanCodex(paths.Codex, cache)...)
	s.store.Upsert(fresh)
}

// ---------------------------------------------------------------------------
// 목록
// ---------------------------------------------------------------------------

type listRow struct {
	ID       string // provider:sessionId — 상세 링크 파라미터
	Provider string
	Label    string
	Ended    string
	Duration string
	Tokens   string
	Prompts  []string
	More     int // 미리보기(2개) 밖의 요청 수
	Agents   int
	Active   bool
}

type usageRow struct {
	Name     string
	Today    string
	Total    string
	Sessions int
	Note     string
}

type listPage struct {
	Token    string
	Provider string // 현재 필터 ("" = 전체)
	Names    []string
	Rows     []listRow
	Total    int
	Today    string
	AllTime  string
	Input    string
	Output   string
	Cache    string
	Tools    []usageRow
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	s.refreshLocalData()
	filter := r.URL.Query().Get("provider")
	records := s.store.Load()

	seen := map[string]bool{}
	page := listPage{Token: s.token, Provider: filter}
	var today, allTime, input, output, cache int64
	for _, summary := range s.usageSnapshot() {
		today += summary.Today.Total
		allTime += summary.Usage.Total
		input += summary.Today.Input
		output += summary.Today.Output
		cache += summary.Today.CacheRead + summary.Today.CacheWrite
		page.Tools = append(page.Tools, usageRow{
			Name: summary.DisplayName, Today: compact(summary.Today.Total),
			Total: compact(summary.Usage.Total), Sessions: summary.Sessions, Note: summary.Note,
		})
	}
	page.Today = compact(today)
	page.AllTime = compact(allTime)
	page.Input = compact(input)
	page.Output = compact(output)
	page.Cache = compact(cache)
	for _, rec := range records {
		if !seen[rec.Provider] {
			seen[rec.Provider] = true
			page.Names = append(page.Names, rec.Provider)
		}
		if filter != "" && rec.Provider != filter {
			continue
		}
		row := listRow{
			ID:       rec.ID(),
			Provider: rec.Provider,
			Label:    label(rec),
			Ended:    relTime(rec.EndedAt),
			Duration: duration(rec.StartedAt, rec.EndedAt),
			Tokens:   compact(rec.TotalTokens),
			Agents:   rec.AgentCount,
			Active:   sessionActive(rec.SourcePath),
		}
		if len(rec.Prompts) > 2 {
			row.Prompts = rec.Prompts[:2]
		} else {
			row.Prompts = rec.Prompts
		}
		if rec.PromptCount > len(row.Prompts) {
			row.More = rec.PromptCount
		}
		page.Rows = append(page.Rows, row)
	}
	page.Total = len(page.Rows)
	render(w, listTmpl, page)
}

func sessionActive(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && time.Since(info.ModTime()) <= session.ActiveGrace
}

// ---------------------------------------------------------------------------
// 상세 — 이 핸들러가 불릴 때(=클릭할 때)에만 원본 로그를 읽는다.
// ---------------------------------------------------------------------------

type detailTurn struct {
	User bool
	Text string
	Time string
}

type detailPage struct {
	Token   string
	Label   string
	Ended   string
	Prompts int
	Tokens  string
	Source  string
	// 요청 하나 + 뒤따르는 응답들 = 한 페어. 최신순(최근 페어 먼저)으로
	// 렌더하되 페어 안은 항상 요청→응답 순서(맥과 동일 규칙).
	Pairs [][]detailTurn
	Error string
}

func (s *Server) handleDetail(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	var rec *session.Record
	for _, cand := range s.store.Load() {
		if cand.ID() == id {
			rec = &cand
			break
		}
	}
	if rec == nil {
		http.NotFound(w, r)
		return
	}

	page := detailPage{
		Token:   s.token,
		Label:   label(*rec),
		Ended:   relTime(rec.EndedAt) + " 종료",
		Prompts: rec.PromptCount,
		Tokens:  compact(rec.TotalTokens),
		Source:  session.ResolveSource(*rec, s.claudeRoot, s.codexRoot),
	}
	turns, err := session.LoadTranscript(*rec, s.claudeRoot, s.codexRoot)
	if err != nil {
		page.Error = err.Error()
	}
	var pair []detailTurn
	for _, t := range turns {
		dt := detailTurn{User: t.Role == "user", Text: t.Text}
		if !t.Timestamp.IsZero() {
			dt.Time = t.Timestamp.Local().Format("15:04:05")
		}
		// 요청(user) 턴이 새 페어를 연다 — 요청 없이 시작하는 선행 응답들도
		// 하나의 페어로 남긴다.
		if dt.User && len(pair) > 0 {
			page.Pairs = append(page.Pairs, pair)
			pair = nil
		}
		pair = append(pair, dt)
	}
	if len(pair) > 0 {
		page.Pairs = append(page.Pairs, pair)
	}
	// 최신순 고정 — 최근 페어가 위로.
	for i, j := 0, len(page.Pairs)-1; i < j; i, j = i+1, j-1 {
		page.Pairs[i], page.Pairs[j] = page.Pairs[j], page.Pairs[i]
	}
	render(w, detailTmpl, page)
}

// ---------------------------------------------------------------------------
// 표시 헬퍼 — 맥 화면과 같은 문구·형식.
// ---------------------------------------------------------------------------

func label(rec session.Record) string {
	if rec.ProjectLabel == "" {
		return "(프로젝트 미상)"
	}
	if rec.GitBranch != "" {
		return rec.ProjectLabel + " · " + rec.GitBranch
	}
	return rec.ProjectLabel
}

func relTime(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "방금"
	case d < time.Hour:
		return fmt.Sprintf("%d분 전", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%d시간 전", int(d.Hours()))
	default:
		return fmt.Sprintf("%d일 전", int(d.Hours()/24))
	}
}

func duration(from, to time.Time) string {
	d := to.Sub(from)
	if d < 0 {
		d = 0
	}
	h, m := int(d.Hours()), int(d.Minutes())%60
	if h > 0 {
		return fmt.Sprintf("%d시간 %d분", h, m)
	}
	return fmt.Sprintf("%d분 %d초", m, int(d.Seconds())%60)
}

func compact(n int64) string {
	f := float64(n)
	switch {
	case n >= 1_000_000_000:
		return fmt.Sprintf("%.2fB", f/1_000_000_000)
	case n >= 1_000_000:
		return fmt.Sprintf("%.2fM", f/1_000_000)
	case n >= 10_000:
		return fmt.Sprintf("%.1fK", f/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}

func render(w http.ResponseWriter, tmpl *template.Template, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = tmpl.Execute(w, data)
}

// ---------------------------------------------------------------------------
// 템플릿 — 외부 요청 없는 자체 완결 페이지.
// ---------------------------------------------------------------------------

const baseCSS = `
:root { --accent:#129178; --warm:#ef7d4a; --text:#202522; --muted:#66706b; --line:#d9dfdc; --bg:#eef2f0; --surface:#fff; --soft:#e8f5f1; }
@media (prefers-color-scheme: dark) {
  :root { --text:#edf2ef; --muted:#9aa6a0; --line:#37423d; --bg:#111613; --surface:#1d2421; --soft:#18362e; }
}
* { box-sizing:border-box; margin:0; }
html { scroll-behavior:smooth; }
body { font-family:-apple-system,'Segoe UI',sans-serif; background:var(--bg); color:var(--text); font-size:13px; line-height:1.5; }
a { color:inherit; text-decoration:none; }
.shell { width:min(100%,560px); min-height:100vh; margin:0 auto; background:var(--surface); border-left:1px solid var(--line); border-right:1px solid var(--line); }
.mast { height:64px; padding:0 18px; display:flex; align-items:center; justify-content:space-between; border-bottom:1px solid var(--line); }
.brand { display:flex; align-items:center; gap:9px; font-size:15px; }
.mark { width:30px; height:30px; display:grid; place-items:center; border-radius:5px; background:var(--accent); color:#fff; font-weight:800; }
.eyebrow { color:var(--muted); font-size:10px; font-weight:700; letter-spacing:.08em; }
.refresh { width:30px; height:30px; display:grid; place-items:center; border:1px solid var(--line); border-radius:5px; font-size:18px; color:var(--muted); }
.nav { height:42px; padding:0 18px; display:flex; align-items:end; gap:20px; border-bottom:1px solid var(--line); }
.nav a { height:42px; display:flex; align-items:center; color:var(--muted); font-weight:600; border-bottom:2px solid transparent; }
.nav a:first-child { color:var(--accent); border-color:var(--accent); }
main { padding:16px 18px 28px; }
.hero { padding:18px; text-align:center; background:var(--soft); border:1px solid color-mix(in srgb,var(--accent) 24%,var(--line)); border-radius:8px; }
.hero .label { color:var(--muted); font-weight:600; }
.hero strong { display:block; margin:3px 0 0; color:var(--accent); font-size:40px; line-height:1.1; font-variant-numeric:tabular-nums; }
.hero small { color:var(--muted); }
.metrics { display:grid; grid-template-columns:repeat(3,1fr); margin-top:12px; border:1px solid var(--line); border-radius:6px; overflow:hidden; }
.metric { padding:9px; text-align:center; border-right:1px solid var(--line); }
.metric:last-child { border:0; }
.metric span { display:block; color:var(--muted); font-size:11px; }
.metric b { font-size:14px; font-variant-numeric:tabular-nums; }
.section-head { display:flex; align-items:center; margin:20px 0 8px; }
.section-head h2 { font-size:13px; }
.section-head span { margin-left:auto; color:var(--muted); font-size:11px; }
.tool-grid { display:grid; grid-template-columns:1fr 1fr; gap:8px; }
.tool { padding:11px; border:1px solid var(--line); border-radius:7px; min-width:0; }
.tool .tool-top { display:flex; gap:6px; align-items:center; }
.tool .dot { width:7px; height:7px; border-radius:50%; background:var(--accent); }
.tool b { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.tool .today { margin-left:auto; color:var(--accent); font-weight:700; }
.tool .meta { margin-top:4px; }
.top { display:flex; align-items:center; gap:7px; padding:14px 0 10px; flex-wrap:wrap; }
h1 { font-size:18px; line-height:1.1; font-weight:700; margin-right:auto; }
.chip { border:1px solid var(--line); border-radius:4px; padding:4px 10px; color:var(--muted); }
.chip.on { border-color:var(--accent); background:var(--accent); color:#fff; font-weight:600; }
.muted { color:var(--muted); }
.card { padding:11px; margin-bottom:8px; display:block; border:1px solid var(--line); border-radius:7px; background:var(--surface); transition:border-color .12s ease; }
.card:hover { border-color:var(--accent); }
.row1 { display:flex; align-items:baseline; gap:8px; }
.row1 b { font-weight:600; }
.tok { margin-left:auto; color:var(--accent); font-weight:600; white-space:nowrap; }
.meta { color:var(--muted); font-size:12px; }
.prompt { color:var(--muted); font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.live { padding:1px 6px; border-radius:4px; background:var(--warm); color:#fff; font-size:10px; font-weight:700; }
.turn { padding:13px 16px; margin-bottom:2px; border-left:3px solid var(--line); background:var(--surface); white-space:pre-wrap; word-break:break-word; }
.turn.user { border-left-color:var(--accent); }
.turn.asst { color:var(--muted); }
.turn .hd { display:flex; gap:6px; font-size:11px; font-weight:600; margin-bottom:6px; }
.turn.user .hd { color:var(--accent); }
.turn.asst .hd { color:var(--muted); }
.turn .hd .t { margin-left:auto; font-weight:400; }
.back { color:var(--accent); font-weight:600; }
.ctl { display:flex; align-items:center; gap:6px; margin-bottom:12px; }
button.chip { background:var(--surface); font:inherit; font-size:12px; cursor:pointer; }
.ctl .sp { flex:1; }
@media (max-width:640px) {
  .shell { border:0; }
  .mast { height:56px; padding:0 14px; }
  .eyebrow { display:none; }
  main { padding:14px; }
  .tool-grid { grid-template-columns:1fr; }
}
`

var listTmpl = template.Must(template.New("list").Parse(`<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>A-mon 세션 기록</title><style>` + baseCSS + `</style>
<div class="shell">
<header class="mast"><div class="brand"><span class="mark">A</span><div><b>A-mon</b><div class="eyebrow">LOCAL AI MONITOR</div></div></div><a class="refresh" href="/{{.Token}}/" title="새로고침">↻</a></header>
<nav class="nav"><a href="#usage">사용량</a><a href="#sessions">최근 세션</a></nav>
<main>
<section id="usage">
  <div class="hero"><span class="label">오늘 사용량</span><strong>{{.Today}}</strong><small>tokens · 전체 누적 {{.AllTime}}</small></div>
  <div class="metrics"><div class="metric"><span>입력</span><b>{{.Input}}</b></div><div class="metric"><span>출력</span><b>{{.Output}}</b></div><div class="metric"><span>캐시</span><b>{{.Cache}}</b></div></div>
  <div class="section-head"><h2>도구별 사용량</h2><span>{{len .Tools}}개 감지</span></div>
  <div class="tool-grid">{{range .Tools}}<div class="tool"><div class="tool-top"><span class="dot"></span><b>{{.Name}}</b><span class="today">{{.Today}}</span></div><div class="meta">누적 {{.Total}}{{if .Sessions}} · {{.Sessions}}세션{{end}}</div></div>{{end}}</div>
</section>
<section id="sessions">
<div class="top">
  <h1>최근 세션</h1>
  <a class="chip {{if not .Provider}}on{{end}}" href="/{{.Token}}/">전체</a>
  {{$p := .Provider}}{{$tok := .Token}}
  {{range .Names}}<a class="chip {{if eq . $p}}on{{end}}" href="/{{$tok}}/?provider={{.}}#sessions">{{.}}</a>{{end}}
  <span class="muted">{{.Total}}개</span>
</div>
{{if not .Rows}}<p class="muted">아직 감지된 세션이 없습니다.</p>{{end}}
{{range .Rows}}
<a class="card" href="/{{$tok}}/session?id={{.ID}}" title="클릭하면 요청·응답 전체를 봅니다">
  <div class="row1"><span class="muted">{{.Provider}}</span><b>{{.Label}}</b>{{if .Active}}<span class="live">LIVE</span>{{end}}<span class="tok">{{.Tokens}}</span></div>
  <div class="meta">{{.Ended}}{{if not .Active}} 종료{{end}} · {{.Duration}}{{if .Agents}} · 에이전트 {{.Agents}}{{end}}</div>
  {{range .Prompts}}<div class="prompt">→ {{.}}</div>{{end}}
  {{if .More}}<div class="prompt">… 총 {{.More}}개 요청</div>{{end}}
</a>
{{end}}
</section>
</main></div>`))

var detailTmpl = template.Must(template.New("detail").Parse(`<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{.Label}} — A-mon 세션</title><style>` + baseCSS + `</style>
<div class="shell"><header class="mast"><div class="brand"><span class="mark">A</span><div><b>A-mon</b><div class="eyebrow">SESSION TRANSCRIPT</div></div></div></header><main>
<div class="top">
  <a class="back" href="/{{.Token}}/">‹ 목록</a>
  <h1><a href="/{{.Token}}/" title="세션 목록으로">{{.Label}}</a></h1>
  <span class="tok">{{.Tokens}}</span>
</div>
<p class="meta" style="margin-bottom:12px">{{.Ended}} · 요청 {{.Prompts}}개{{if .Source}} · {{.Source}}{{end}}</p>
{{if .Error}}<p class="muted">{{.Error}} — 로그가 정리됐거나 다른 기기에서 만든 세션일 수 있습니다.</p>{{end}}
<div class="ctl">
  <span class="sp"></span>
  <button type="button" id="jump-top" class="chip" title="맨 위로 (최근)">↑ 맨 위</button>
  <button type="button" id="jump-bottom" class="chip" title="맨 아래로 (처음)">↓ 맨 아래</button>
</div>
{{range .Pairs}}<div class="pair">
{{range .}}<div class="turn {{if .User}}user{{else}}asst{{end}}">
  <div class="hd"><span>{{if .User}}→ 요청{{else}}↳ 응답{{end}}</span>{{if .Time}}<span class="t">{{.Time}}</span>{{end}}</div>{{.Text}}</div>
{{end}}</div>
{{end}}
<script>
// 서버가 최신순(최근 페어 먼저)으로 렌더한다 — 점프 버튼만 클라이언트 처리.
(function () {
  function jump(top) {
    window.scrollTo({ top: top ? 0 : document.body.scrollHeight, behavior: 'smooth' });
  }
  document.getElementById('jump-top').addEventListener('click', function () { jump(true); });
  document.getElementById('jump-bottom').addEventListener('click', function () { jump(false); });
})();
</script></main></div>`))
