// A-mon Windows — 하단 트레이 상주 앱.
//
// macOS 메뉴바 앱(macos/)의 Windows 대응: 10분 주기로 로컬 AI 도구 로그
// (Claude Code·Codex CLI·OpenCode·Cursor)를 스캔해 트레이 메뉴에 표시하고,
// 스캔 결과를 로컬 usage.db 에 적재해 설정된 서버로 에이전트 대시보드를 업로드한다.
//
// 세션 기록(종료 세션 + 요청·응답 전문)은 macOS 와 동일 규칙으로 수집하되,
// systray 에는 창이 없어 목록·상세 화면은 로컬 브라우저 페이지로 제공한다
// (internal/webui). Claude·Codex CLI 자격증명이 있으면 라이브 세션/주간 한도도
// 함께 조회해 네이티브 팝업에 표시한다.
package main

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"time"

	"fyne.io/systray"

	"github.com/athens96/amon/windows/internal/config"
	"github.com/athens96/amon/windows/internal/pet"
	"github.com/athens96/amon/windows/internal/popup"
	"github.com/athens96/amon/windows/internal/provider"
	"github.com/athens96/amon/windows/internal/scan"
	"github.com/athens96/amon/windows/internal/session"
	"github.com/athens96/amon/windows/internal/update"
	"github.com/athens96/amon/windows/internal/webui"
)

//go:embed assets/amon.ico
var trayIcon []byte

// appVersion — 기본값. 릴리즈 빌드는 Makefile 이 -ldflags "-X main.appVersion=…"
// 로 주입한다(단일 출처 = windows/Makefile VERSION, macOS 와 정책 공유).
var appVersion = "0.3.38"

const scanInterval = 10 * time.Minute
const petScanInterval = 5 * time.Second

// menu — 갱신이 필요한 트레이 메뉴 항목 모음.
type menu struct {
	today     *systray.MenuItem   // 오늘 합계
	tools     []*systray.MenuItem // 도구별 4줄
	status    *systray.MenuItem   // 마지막 스캔·보고 상태
	install   *systray.MenuItem   // 새 버전 설치 (발견 시에만 표시)
	sessions  *systray.MenuItem   // 세션 기록 (브라우저)
	refresh   *systray.MenuItem
	sendNow   *systray.MenuItem
	openCfg   *systray.MenuItem
	openWeb   *systray.MenuItem
	petToggle *systray.MenuItem
	petLive   *systray.MenuItem
	petTask   *systray.MenuItem
	petImport *systray.MenuItem
	petStore  *systray.MenuItem
	quit      *systray.MenuItem
	open      chan struct{}
	panel     *popup.Window
	petWindow *pet.Window
	providers *provider.Manager
	records   []session.Record
}

func main() {
	systray.Run(onReady, func() {})
}

func onReady() {
	systray.SetIcon(trayIcon)
	systray.SetTooltip("A-mon — AI 사용량 수집기")

	cfg, _ := config.Load()
	m := &menu{
		open: make(chan struct{}, 1), panel: popup.New(),
		petWindow: pet.NewWindow(petWindowSettings(cfg)),
		providers: provider.NewManager(),
	}
	systray.SetOnClick(func() {
		select {
		case m.open <- struct{}{}:
		default:
		}
	})
	systray.SetOnRightClick(func() {
		select {
		case m.open <- struct{}{}:
		default:
		}
	})
	m.today = systray.AddMenuItem("오늘 사용량 계산 중…", "오늘 로컬 토큰 합계")
	m.today.Disable()
	systray.AddSeparator()
	// 도구 7종: Claude·Codex·OpenCode·Cursor·Gemini·Qwen·Copilot (ScanAll 순서와 동일).
	for i := 0; i < 7; i++ {
		item := systray.AddMenuItem("…", "")
		item.Disable()
		m.tools = append(m.tools, item)
	}
	systray.AddSeparator()
	m.status = systray.AddMenuItem("아직 보고 안 함", "마지막 스캔·서버 보고 상태")
	m.status.Disable()
	systray.AddSeparator()
	m.petToggle = systray.AddMenuItem("펫 잠재우기", "데스크톱 펫 표시/숨기기")
	m.petLive = systray.AddMenuItemCheckbox(
		"현재 작업 감지", "로컬 세션만 읽으며 서버로 전송하지 않습니다",
		cfg.Pet.LocalActivityEnabledValue(),
	)
	m.petTask = systray.AddMenuItemCheckbox(
		"작업 말풍선 표시", "현재 입력·출력 요약과 토큰을 펫 옆에 표시",
		cfg.Pet.ShowsCurrentTaskValue(),
	)
	m.petImport = systray.AddMenuItem("Codex 펫 가져오기...", "codex-pets ZIP 또는 PNG 가져오기")
	m.petStore = systray.AddMenuItem("Codex 펫 다운로드", "https://codex-pets.net/ 열기")
	m.install = systray.AddMenuItem("", "서버 릴리즈 채널의 새 버전을 설치")
	m.install.Hide()
	m.sessions = systray.AddMenuItem("세션 기록 보기", "종료된 세션의 요청·응답 전문 (브라우저)")
	m.refresh = systray.AddMenuItem("새로고침", "지금 다시 스캔")
	m.sendNow = systray.AddMenuItem("지금 보고", "지금 스캔하고 집계 사용량을 서버로 업로드")
	m.openCfg = systray.AddMenuItem("설정 파일 열기", "server_url·user_key·경로 편집")
	m.openWeb = systray.AddMenuItem("웹 대시보드 열기", "AI 모니터 웹 열기")
	systray.AddSeparator()
	m.quit = systray.AddMenuItem(fmt.Sprintf("종료 (v%s)", appVersion), "A-mon 종료")
	refreshPetMenu(m, cfg)

	// 클릭 핸들러 + 주기 스캔 루프.
	go loop(m)
}

func loop(m *menu) {
	// 서버가 이 버전보다 높은 windows 릴리즈를 갖고 있으면 설치 메뉴가 나타난다.
	var pending *update.Info
	hub := newSessionHub()
	ds := newDashSync()
	if ds != nil {
		defer ds.close()
	}

	cycle(m, hub, ds, true)
	pending = checkUpdate(m)
	maybeAutoInstall(m, pending)

	ticker := time.NewTicker(scanInterval)
	defer ticker.Stop()
	petTicker := time.NewTicker(petScanInterval)
	defer petTicker.Stop()
	defer m.petWindow.Close()
	for {
		select {
		case <-ticker.C:
			cycle(m, hub, ds, true)
			pending = checkUpdate(m)
			maybeAutoInstall(m, pending)
		case <-m.refresh.ClickedCh:
			m.providers.Invalidate()
			cycle(m, hub, ds, false)
			pending = checkUpdate(m)
			maybeAutoInstall(m, pending)
		case <-m.sendNow.ClickedCh:
			cycle(m, hub, ds, true)
		case <-petTicker.C:
			cfg, err := config.Load()
			if err != nil {
				continue
			}
			if cfg.Pet.LocalActivityEnabledValue() {
				m.records = hub.scan()
			}
			updatePetWithConfig(m, m.records, cfg)
		case <-m.install.ClickedCh:
			installUpdate(m, pending)
		case <-m.open:
			_, data := cycle(m, hub, ds, false)
			m.panel.Toggle(data)
		case <-m.panel.Refresh:
			m.providers.Invalidate()
			cycle(m, hub, ds, false)
		case <-m.panel.Sessions:
			summaries, _ := cycle(m, hub, ds, false)
			hub.openDashboard(summaries, "sessions")
		case <-m.panel.Config:
			showSettings(m.panel)
		case settings := <-m.panel.SaveSettings:
			cfg, err := config.Load()
			if err == nil {
				autoUpdate := settings.AutoUpdate
				cfg.AutoUpdate = &autoUpdate
				cfg.Pet.Enabled = config.Bool(settings.PetEnabled)
				if settings.AutomaticPaths {
					cfg.Paths = scan.Paths{}
				}
				_ = config.Save(cfg)
				refreshPetMenu(m, cfg)
				updatePetWithConfig(m, m.records, cfg)
				cycle(m, hub, ds, false)
			}
		case <-m.panel.Advanced:
			openConfig()
		case <-m.panel.Quit:
			m.panel.Close()
			systray.Quit()
			return
		case <-m.sessions.ClickedCh:
			summaries, _ := cycle(m, hub, ds, false)
			hub.openDashboard(summaries, "sessions")
		case <-m.openCfg.ClickedCh:
			showSettings(m.panel)
		case <-m.openWeb.ClickedCh:
			if cfg, err := config.Load(); err == nil && cfg.ServerURL != "" {
				openURL(cfg.ServerURL)
			}
		case <-m.petToggle.ClickedCh:
			togglePetEnabled(m)
		case <-m.petLive.ClickedCh:
			togglePetActivity(m)
		case <-m.petTask.ClickedCh:
			togglePetTask(m)
		case <-m.petImport.ClickedCh:
			importPet(m)
		case <-m.petStore.ClickedCh:
			openURL("https://codex-pets.net/")
		case <-m.petWindow.Dashboard:
			_, data := cycle(m, hub, ds, false)
			m.panel.Toggle(data)
		case <-m.petWindow.TogglePet:
			togglePetEnabled(m)
		case <-m.petWindow.ToggleActivity:
			togglePetActivity(m)
		case <-m.petWindow.ToggleTask:
			togglePetTask(m)
		case <-m.petWindow.ImportPet:
			importPet(m)
		case <-m.petWindow.DownloadPets:
			openURL("https://codex-pets.net/")
		case <-m.petWindow.Settings:
			showSettings(m.panel)
		case position := <-m.petWindow.Moved:
			savePetPosition(position)
		case <-m.petWindow.Quit:
			m.panel.Close()
			m.petWindow.Close()
			systray.Quit()
			return
		case <-m.quit.ClickedCh:
			m.panel.Close()
			m.petWindow.Close()
			systray.Quit()
			return
		}
	}
}

// cycle — 한 스캔 주기: 사용량 스캔·메뉴 갱신 → 세션 스캔·기록 보고 → usage.db 적재 +
// (설정됨·내용 변경시) 에이전트 대시보드 업로드.
func cycle(m *menu, hub *sessionHub, ds *dashSync, periodic bool) ([]scan.ToolSummary, popup.Data) {
	summaries := scanAndRefresh(m, periodic)
	records := hub.scan()
	m.records = records
	ds.persist(summaries, records)
	snapshots := m.providers.Fetch(context.Background())
	data := dashboardData(summaries, records, snapshots)
	m.panel.Update(data)
	updatePet(m, records)
	systray.SetIcon(statusIcon(trayIcon, data.Active, totalToday(summaries)))
	tip := fmt.Sprintf("A-mon | 오늘 %s tokens", data.Today)
	if data.Active > 0 {
		tip += fmt.Sprintf(" | LIVE %d", data.Active)
	}
	if quota := quotaTooltip(snapshots); quota != "" {
		tip += " | " + quota
	}
	systray.SetTooltip(tip)
	return summaries, data
}

func dashboardData(summaries []scan.ToolSummary, records []session.Record, snapshots []provider.Snapshot) popup.Data {
	var today, allTime, input, output, cache int64
	data := popup.Data{Updated: time.Now().Format("15:04"), Status: "업데이트 " + time.Now().Format("15:04")}
	for _, s := range summaries {
		today += s.Today.Total
		allTime += s.Usage.Total
		input += s.Today.Input
		output += s.Today.Output
		cache += s.Today.CacheRead + s.Today.CacheWrite
		data.Tools = append(data.Tools, popup.Tool{Name: s.DisplayName, Today: compact(s.Today.Total), Total: compact(s.Usage.Total)})
	}
	data.Today, data.AllTime = compact(today), compact(allTime)
	data.Input, data.Output, data.Cache = compact(input), compact(output), compact(cache)
	for _, snapshot := range snapshots {
		item := popup.Provider{Name: snapshot.Name, Plan: snapshot.Plan, Status: snapshot.Status}
		for _, metric := range snapshot.Metrics {
			item.Metrics = append(item.Metrics, popup.ProviderMetric{
				Label: metric.Label, Used: metric.UsedPercent,
				Remaining: fmt.Sprintf("%.0f%% 남음", metric.RemainingPercent()),
				Reset:     resetLabel(metric.ResetsAt),
			})
		}
		data.Providers = append(data.Providers, item)
	}
	for _, rec := range records {
		active := recordActive(rec)
		if active {
			data.Active++
		}
		if len(data.Sessions) >= 3 {
			continue
		}
		label := rec.ProjectLabel
		if label == "" {
			label = "프로젝트 미상"
		}
		ended := relativeTime(rec.EndedAt)
		if active {
			ended = "진행 중"
		}
		data.Sessions = append(data.Sessions, popup.Session{Label: label, Provider: rec.Provider, Ended: ended, Active: active})
	}
	return data
}

func quotaTooltip(snapshots []provider.Snapshot) string {
	var name, label string
	remaining := 101.0
	for _, snapshot := range snapshots {
		for _, metric := range snapshot.Metrics {
			if value := metric.RemainingPercent(); value < remaining {
				name, label, remaining = snapshot.Name, metric.Label, value
			}
		}
	}
	if remaining > 100 {
		return ""
	}
	return fmt.Sprintf("%s %s %.0f%% 남음", name, label, remaining)
}

func resetLabel(reset time.Time) string {
	if reset.IsZero() {
		return ""
	}
	remaining := time.Until(reset)
	switch {
	case remaining <= 0:
		return "곧 갱신"
	case remaining < time.Hour:
		return fmt.Sprintf("%d분", max(1, int(remaining.Minutes())))
	case remaining < 24*time.Hour:
		return fmt.Sprintf("%d시간", int(remaining.Hours()))
	default:
		return fmt.Sprintf("%d일", int(remaining.Hours()/24))
	}
}

func totalToday(summaries []scan.ToolSummary) int64 {
	var total int64
	for _, s := range summaries {
		total += s.Today.Total
	}
	return total
}

func recordActive(rec session.Record) bool {
	if rec.SourcePath == "" {
		return false
	}
	info, err := os.Stat(rec.SourcePath)
	if err != nil || time.Since(info.ModTime()) > session.ActiveGrace {
		return false
	}
	if rec.Status != "" {
		return pet.StatusFromString(rec.Status) == pet.StatusRunning
	}
	return time.Since(info.ModTime()) <= pet.SourceActiveInterval
}

func relativeTime(t time.Time) string {
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

// statusIcon overlays a compact state dot on the existing icon. Windows does
// not support menu-bar text beside a tray icon, so detail stays in the tooltip.
func statusIcon(ico []byte, active int, today int64) []byte {
	if len(ico) < 22 {
		return ico
	}
	count := int(binary.LittleEndian.Uint16(ico[4:6]))
	var payload []byte
	for i := 0; i < count; i++ {
		entry := 6 + i*16
		if entry+16 > len(ico) {
			break
		}
		w := int(ico[entry])
		if w == 0 {
			w = 256
		}
		if w != 32 {
			continue
		}
		size := int(binary.LittleEndian.Uint32(ico[entry+8 : entry+12]))
		offset := int(binary.LittleEndian.Uint32(ico[entry+12 : entry+16]))
		if offset >= 0 && size > 0 && offset+size <= len(ico) {
			payload = ico[offset : offset+size]
			break
		}
	}
	base, err := png.Decode(bytes.NewReader(payload))
	if err != nil {
		return ico
	}
	bounds := base.Bounds()
	canvas := image.NewRGBA(bounds)
	draw.Draw(canvas, bounds, base, bounds.Min, draw.Src)
	dot := color.RGBA{R: 135, G: 145, B: 140, A: 255}
	if today > 0 {
		dot = color.RGBA{R: 97, G: 97, B: 255, A: 255}
	}
	if active > 0 {
		dot = color.RGBA{R: 97, G: 97, B: 255, A: 255}
	}
	cx, cy, radius := bounds.Max.X-6, bounds.Max.Y-6, 5
	for y := cy - radius - 1; y <= cy+radius+1; y++ {
		for x := cx - radius - 1; x <= cx+radius+1; x++ {
			dx, dy := x-cx, y-cy
			d2 := dx*dx + dy*dy
			if d2 <= (radius+1)*(radius+1) {
				c := dot
				if d2 > radius*radius {
					c = color.RGBA{R: 255, G: 255, B: 255, A: 255}
				}
				canvas.Set(x, y, c)
			}
		}
	}
	var pngData bytes.Buffer
	if png.Encode(&pngData, canvas) != nil {
		return ico
	}
	b := pngData.Bytes()
	out := make([]byte, 22+len(b))
	binary.LittleEndian.PutUint16(out[2:4], 1)
	binary.LittleEndian.PutUint16(out[4:6], 1)
	out[6], out[7] = byte(bounds.Dx()), byte(bounds.Dy())
	binary.LittleEndian.PutUint16(out[10:12], 1)
	binary.LittleEndian.PutUint16(out[12:14], 32)
	binary.LittleEndian.PutUint32(out[14:18], uint32(len(b)))
	binary.LittleEndian.PutUint32(out[18:22], 22)
	copy(out[22:], b)
	return out
}

// sessionHub — 이 기기의 로컬 세션 기록 수집 상태(저장소·파싱 캐시).
//
// 스캔 주기는 트레이 루프(10분)를 따른다 — 맥(60초)보다 길지만 세션 기록은
// 실시간 데이터가 아니고, 지문 캐시 덕에 스캔 자체는 활성 파일 몇 개만 읽는다.
type sessionHub struct {
	store *session.Store
	cache *session.FileCache
}

func newSessionHub() *sessionHub {
	dir, err := config.Dir()
	if err != nil {
		dir = "."
	}
	return &sessionHub{
		store: &session.Store{Path: filepath.Join(dir, "history", "sessions.jsonl")},
		cache: session.LoadFileCache(filepath.Join(dir, "cache", "session-files.json")),
	}
}

// scan — 종료 세션 스캔 → 이 기기의 로컬 저장소 적재.
// 병합된 전체 세션 기록을 돌려준다(usage.db sessions 미러용).
func (h *sessionHub) scan() []session.Record {
	cfg, _ := config.Load()
	paths := cfg.Paths.WithDefaults()
	fresh := session.ScanClaude(paths.Claude, h.cache)
	fresh = append(fresh, session.ScanCodex(paths.Codex, h.cache)...)
	h.cache.Save()
	return h.store.Upsert(fresh)
}

// openDashboard — 사용량과 최근 세션을 독립 앱 창으로 연다.
func (h *sessionHub) openDashboard(summaries []scan.ToolSummary, section string) {
	cfg, _ := config.Load()
	paths := cfg.Paths.WithDefaults()
	srv, err := webui.Ensure(h.store, paths.Claude, paths.Codex)
	if err != nil {
		return
	}
	srv.UpdateSummaries(summaries)
	srv.SetPaths(paths)
	url := srv.URL()
	if section != "" {
		url += "#" + section
	}
	openAppURL(url)
}

// checkUpdate — 서버 릴리즈 채널 확인. 새 버전이 있으면 설치 메뉴를 노출한다.
func checkUpdate(m *menu) *update.Info {
	cfg, _ := config.Load()
	if cfg.ServerURL == "" {
		return nil
	}
	info, err := update.CheckLatest(cfg.ServerURL, appVersion)
	if err != nil || info == nil {
		m.install.Hide()
		return nil
	}
	m.install.SetTitle(fmt.Sprintf("⬇ 새 버전 v%s 설치 (현재 v%s)", info.Version, appVersion))
	m.install.Show()
	return info
}

// maybeAutoInstall — 새 버전이 감지됐고 config 의 auto_update 가 켜져 있으면(기본)
// 클릭 없이 바로 설치한다. 주기 체크(10분)와 합쳐져 재실행 없이도 업데이트된다.
func maybeAutoInstall(m *menu, pending *update.Info) {
	if pending == nil {
		return
	}
	if cfg, err := config.Load(); err != nil || !cfg.AutoUpdateEnabled() {
		return
	}
	installUpdate(m, pending)
}

// installUpdate — 다운로드·검증 후 교체 스크립트를 띄우고 앱을 종료한다.
func installUpdate(m *menu, info *update.Info) {
	if info == nil {
		return
	}
	cfg, _ := config.Load()
	m.install.SetTitle(fmt.Sprintf("v%s 다운로드 중…", info.Version))
	m.install.Disable()
	if err := update.DownloadAndApply(cfg.ServerURL, *info); err != nil {
		m.install.SetTitle(fmt.Sprintf("업데이트 실패: %v", err))
		m.install.Enable()
		return
	}
	m.status.SetTitle("업데이트 설치 — 재시작합니다…")
	time.Sleep(500 * time.Millisecond) // 스크립트가 분리 실행될 시간
	systray.Quit()
}

// scanAndRefresh — 스캔 후 트레이 메뉴·상태를 갱신하고 스캔 요약을 돌려준다. 서버 전송
// (에이전트 대시보드 업로드·세션 기록)은 cycle 의 후속 단계가 담당한다. periodic 이면
// (주기 스캔·"지금 보고") 서버 미설정 시 안내를 띄운다.
func scanAndRefresh(m *menu, periodic bool) []scan.ToolSummary {
	cfg, _ := config.Load()
	summaries := scan.ScanAll(cfg.Paths)

	var grandToday, grandTotal int64
	for _, s := range summaries {
		grandToday += s.Today.Total
		grandTotal += s.Usage.Total
	}
	m.today.SetTitle(fmt.Sprintf("오늘 %s tokens · 누적 %s", compact(grandToday), compact(grandTotal)))
	systray.SetTooltip(fmt.Sprintf("A-mon — 오늘 %s tokens", compact(grandToday)))

	for i, s := range summaries {
		if i >= len(m.tools) {
			break
		}
		line := fmt.Sprintf("%s — 오늘 %s · 누적 %s", s.DisplayName, compact(s.Today.Total), compact(s.Usage.Total))
		if s.Note != "" && s.Usage.Total == 0 {
			line = fmt.Sprintf("%s — %s", s.DisplayName, s.Note)
		} else if top := topModel(s.Models, s.Usage.Total); top != "" {
			line += " · " + top
		}
		m.tools[i].SetTitle(line)
		m.tools[i].SetTooltip(fmt.Sprintf(
			"입력 %s · 출력 %s · 캐시 %s · 세션 %d",
			compact(s.Usage.Input), compact(s.Usage.Output),
			compact(s.Usage.CacheRead+s.Usage.CacheWrite), s.Sessions))
	}

	now := time.Now().Format("15:04")
	if periodic && !cfg.ReportConfigured() {
		m.status.SetTitle(fmt.Sprintf("스캔 %s · 서버 미설정(설정 파일 편집)", now))
		return summaries
	}
	m.status.SetTitle(fmt.Sprintf("스캔 완료 %s", now))
	return summaries
}

// topModel — 모델별 누적 상위 1개를 "opus-4-8 81%" 형태로.
func topModel(models map[string]int64, total int64) string {
	if total <= 0 || len(models) == 0 {
		return ""
	}
	type kv struct {
		k string
		v int64
	}
	var list []kv
	for k, v := range models {
		list = append(list, kv{k, v})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].v > list[j].v })
	name := list[0].k
	if name == "unknown" {
		return ""
	}
	for _, prefix := range []string{"claude-", "models/"} {
		if len(name) > len(prefix) && name[:len(prefix)] == prefix {
			name = name[len(prefix):]
		}
	}
	return fmt.Sprintf("%s %d%%", name, list[0].v*100/total)
}

// compact — 12.3M 형태.
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

// openConfig — 설정 파일을 OS 기본 편집기로 연다.
func openConfig() {
	path, err := config.Path()
	if err != nil {
		return
	}
	if _, err := config.Load(); err != nil {
		return // Load 가 없으면 기본값을 만들어 둔다
	}
	switch runtime.GOOS {
	case "windows":
		_ = exec.Command("notepad.exe", path).Start()
	case "darwin":
		_ = exec.Command("open", "-t", path).Start()
	default:
		_ = exec.Command("xdg-open", path).Start()
	}
}

func showSettings(panel *popup.Window) {
	cfg, err := config.Load()
	if err != nil {
		return
	}
	defaults := scan.DefaultPaths()
	automaticPaths := cfg.Paths == (scan.Paths{}) || cfg.Paths == defaults
	panel.ShowSettings(popup.Settings{
		AutoUpdate:      cfg.AutoUpdateEnabled(),
		AutomaticPaths:  automaticPaths,
		ServerConnected: cfg.ReportConfigured(),
		PetEnabled:      cfg.Pet.EnabledValue(),
	})
}

func petWindowSettings(cfg config.Config) pet.WindowSettings {
	return pet.WindowSettings{
		Enabled:              cfg.Pet.EnabledValue(),
		LocalActivityEnabled: cfg.Pet.LocalActivityEnabledValue(),
		ShowsCurrentTask:     cfg.Pet.ShowsCurrentTaskValue(),
		SpritePath:           cfg.Pet.SpritePath,
		PositionX:            cfg.Pet.PositionX,
		PositionY:            cfg.Pet.PositionY,
	}
}

func updatePet(m *menu, records []session.Record) {
	cfg, err := config.Load()
	if err != nil {
		return
	}
	updatePetWithConfig(m, records, cfg)
}

func updatePetWithConfig(m *menu, records []session.Record, cfg config.Config) {
	var live []pet.LiveRecord
	if cfg.Pet.LocalActivityEnabledValue() {
		now := time.Now()
		for _, record := range records {
			if record.SourcePath == "" {
				continue
			}
			info, err := os.Stat(record.SourcePath)
			if err != nil || now.Sub(info.ModTime()) > session.ActiveGrace {
				continue
			}
			live = append(live, pet.NewLiveRecord(record, pet.RecordState{
				Lifecycle:  record.Status,
				ModifiedAt: info.ModTime(),
				UpdatedAt:  record.EndedAt,
			}))
		}
	}
	m.petWindow.Update(
		pet.Presentations(live, time.Now()),
		petWindowSettings(cfg),
	)
	refreshPetMenu(m, cfg)
}

func refreshPetMenu(m *menu, cfg config.Config) {
	if cfg.Pet.EnabledValue() {
		m.petToggle.SetTitle("펫 잠재우기")
	} else {
		m.petToggle.SetTitle("펫 깨우기")
	}
	if cfg.Pet.LocalActivityEnabledValue() {
		m.petLive.Check()
	} else {
		m.petLive.Uncheck()
	}
	if cfg.Pet.ShowsCurrentTaskValue() {
		m.petTask.Check()
	} else {
		m.petTask.Uncheck()
	}
}

func togglePetEnabled(m *menu) {
	cfg, err := config.Load()
	if err != nil {
		return
	}
	cfg.Pet.Enabled = config.Bool(!cfg.Pet.EnabledValue())
	if config.Save(cfg) != nil {
		return
	}
	updatePetWithConfig(m, m.records, cfg)
}

func togglePetActivity(m *menu) {
	cfg, err := config.Load()
	if err != nil {
		return
	}
	cfg.Pet.LocalActivityEnabled = config.Bool(!cfg.Pet.LocalActivityEnabledValue())
	if config.Save(cfg) != nil {
		return
	}
	updatePetWithConfig(m, m.records, cfg)
}

func togglePetTask(m *menu) {
	cfg, err := config.Load()
	if err != nil {
		return
	}
	cfg.Pet.ShowsCurrentTask = config.Bool(!cfg.Pet.ShowsCurrentTaskValue())
	if config.Save(cfg) != nil {
		return
	}
	updatePetWithConfig(m, m.records, cfg)
}

func importPet(m *menu) {
	source, err := pet.SelectPetFile()
	if err != nil {
		if !errors.Is(err, pet.ErrDialogCancelled) {
			m.status.SetTitle("펫 파일 선택 실패: " + err.Error())
		}
		return
	}
	dir, err := config.Dir()
	if err != nil {
		return
	}
	destination := filepath.Join(dir, "pets", "spritesheet.png")
	asset, err := pet.InstallAsset(source, destination)
	if err != nil {
		m.status.SetTitle("펫 가져오기 실패: " + err.Error())
		return
	}
	cfg, err := config.Load()
	if err != nil {
		return
	}
	cfg.Pet.SpritePath = destination
	cfg.Pet.SpriteVersion = 1
	cfg.Pet.Enabled = config.Bool(true)
	if config.Save(cfg) != nil {
		return
	}
	name := asset.DisplayName
	if name == "" {
		name = "Codex 호환"
	}
	m.status.SetTitle(fmt.Sprintf("%s 펫 적용 · %d×%d PNG", name, asset.Width, asset.Height))
	updatePetWithConfig(m, m.records, cfg)
}

func savePetPosition(position pet.Position) {
	cfg, err := config.Load()
	if err != nil {
		return
	}
	cfg.Pet.PositionX = config.Int(position.X)
	cfg.Pet.PositionY = config.Int(position.Y)
	_ = config.Save(cfg)
}

// openURL — 기본 브라우저로 URL 열기.
func openURL(url string) {
	switch runtime.GOOS {
	case "windows":
		_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		_ = exec.Command("open", url).Start()
	default:
		_ = exec.Command("xdg-open", url).Start()
	}
}

// openAppURL — Edge/Chrome 의 app mode 로 브라우저 장식 없는 A-mon 창을 연다.
// 지원 브라우저를 찾지 못하면 시스템 기본 브라우저로 폴백한다.
func openAppURL(url string) {
	if runtime.GOOS != "windows" {
		openURL(url)
		return
	}
	candidates := []string{
		filepath.Join(os.Getenv("ProgramFiles(x86)"), "Microsoft", "Edge", "Application", "msedge.exe"),
		filepath.Join(os.Getenv("ProgramFiles"), "Microsoft", "Edge", "Application", "msedge.exe"),
		filepath.Join(os.Getenv("LOCALAPPDATA"), "Microsoft", "Edge", "Application", "msedge.exe"),
		filepath.Join(os.Getenv("ProgramFiles"), "Google", "Chrome", "Application", "chrome.exe"),
	}
	for _, browser := range candidates {
		if browser == "" {
			continue
		}
		if _, err := os.Stat(browser); err == nil {
			_ = exec.Command(browser, "--app="+url, "--window-size=560,720").Start()
			return
		}
	}
	openURL(url)
}
