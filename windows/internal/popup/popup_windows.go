//go:build windows

// Package popup provides the compact native dashboard attached to the tray icon.
package popup

import (
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

type Tool struct {
	Name, Today, Total string
}

type Session struct {
	Label, Provider, Ended string
	Active                 bool
}

type ProviderMetric struct {
	Label, Remaining, Reset string
	Used                    float64
}

type Provider struct {
	Name, Plan, Status string
	Metrics            []ProviderMetric
}

type Data struct {
	Today, AllTime, Input, Output, Cache string
	Updated, Status                      string
	Active                               int
	Tools                                []Tool
	Sessions                             []Session
	Providers                            []Provider
}

type Settings struct {
	AutoUpdate      bool
	AutomaticPaths  bool
	ServerConnected bool
	PetEnabled      bool
}

type Window struct {
	Refresh      chan struct{}
	Sessions     chan struct{}
	Config       chan struct{}
	Advanced     chan struct{}
	SaveSettings chan Settings
	Quit         chan struct{}

	mu           sync.RWMutex
	data         Data
	settings     Settings
	settingsView bool
	hwnd         uintptr
	visible      bool
	ready        chan struct{}
}

const (
	width  = 496
	height = 540

	wmShow     = 0x8001
	wmRefresh  = 0x8002
	wmClose    = 0x8003
	wmSettings = 0x8004
)

var current *Window

var (
	user32                 = syscall.NewLazyDLL("user32.dll")
	gdi32                  = syscall.NewLazyDLL("gdi32.dll")
	kernel32               = syscall.NewLazyDLL("kernel32.dll")
	dwmapi                 = syscall.NewLazyDLL("dwmapi.dll")
	pRegisterClassEx       = user32.NewProc("RegisterClassExW")
	pCreateWindowEx        = user32.NewProc("CreateWindowExW")
	pDefWindowProc         = user32.NewProc("DefWindowProcW")
	pShowWindow            = user32.NewProc("ShowWindow")
	pSetWindowPos          = user32.NewProc("SetWindowPos")
	pSetForegroundWindow   = user32.NewProc("SetForegroundWindow")
	pGetMessage            = user32.NewProc("GetMessageW")
	pTranslateMessage      = user32.NewProc("TranslateMessage")
	pDispatchMessage       = user32.NewProc("DispatchMessageW")
	pPostMessage           = user32.NewProc("PostMessageW")
	pBeginPaint            = user32.NewProc("BeginPaint")
	pEndPaint              = user32.NewProc("EndPaint")
	pGetClientRect         = user32.NewProc("GetClientRect")
	pFillRect              = user32.NewProc("FillRect")
	pInvalidateRect        = user32.NewProc("InvalidateRect")
	pGetCursorPos          = user32.NewProc("GetCursorPos")
	pMonitorFromPoint      = user32.NewProc("MonitorFromPoint")
	pGetMonitorInfo        = user32.NewProc("GetMonitorInfoW")
	pLoadCursor            = user32.NewProc("LoadCursorW")
	pPostQuitMessage       = user32.NewProc("PostQuitMessage")
	pCreateSolidBrush      = gdi32.NewProc("CreateSolidBrush")
	pCreatePen             = gdi32.NewProc("CreatePen")
	pDeleteObject          = gdi32.NewProc("DeleteObject")
	pCreateFont            = gdi32.NewProc("CreateFontW")
	pSelectObject          = gdi32.NewProc("SelectObject")
	pSetTextColor          = gdi32.NewProc("SetTextColor")
	pSetBkMode             = gdi32.NewProc("SetBkMode")
	pRoundRect             = gdi32.NewProc("RoundRect")
	pDrawText              = user32.NewProc("DrawTextW")
	pGetModuleHandle       = kernel32.NewProc("GetModuleHandleW")
	pDwmSetWindowAttribute = dwmapi.NewProc("DwmSetWindowAttribute")
)

type point struct{ X, Y int32 }
type rect struct{ Left, Top, Right, Bottom int32 }
type msg struct {
	Hwnd           uintptr
	Msg            uint32
	WParam, LParam uintptr
	Time           uint32
	Pt             point
}
type paintStruct struct {
	Hdc                uintptr
	Erase              int32
	Paint              rect
	Restore, IncUpdate int32
	Reserved           [32]byte
}
type wndClassEx struct {
	Size                               uint32
	Style                              uint32
	WndProc                            uintptr
	ClsExtra, WndExtra                 int32
	Instance, Icon, Cursor, Background uintptr
	MenuName, ClassName                *uint16
	IconSm                             uintptr
}
type monitorInfo struct {
	Size          uint32
	Monitor, Work rect
	Flags         uint32
}

func New() *Window {
	w := &Window{
		Refresh: make(chan struct{}, 1), Sessions: make(chan struct{}, 1),
		Config: make(chan struct{}, 1), Advanced: make(chan struct{}, 1),
		SaveSettings: make(chan Settings, 1), Quit: make(chan struct{}, 1), ready: make(chan struct{}),
	}
	current = w
	go w.run()
	select {
	case <-w.ready:
	case <-time.After(2 * time.Second):
	}
	return w
}

func (w *Window) ShowSettings(settings Settings) {
	w.mu.Lock()
	w.settings = settings
	w.settingsView = true
	hwnd := w.hwnd
	w.mu.Unlock()
	if hwnd != 0 {
		pPostMessage.Call(hwnd, wmSettings, 0, 0)
	}
}

func (w *Window) Toggle(data Data) {
	w.mu.Lock()
	w.data = data
	hwnd := w.hwnd
	w.mu.Unlock()
	if hwnd != 0 {
		pPostMessage.Call(hwnd, wmShow, 0, 0)
	}
}

func (w *Window) Update(data Data) {
	w.mu.Lock()
	w.data = data
	hwnd, visible := w.hwnd, w.visible
	w.mu.Unlock()
	if hwnd != 0 && visible {
		pPostMessage.Call(hwnd, wmRefresh, 0, 0)
	}
}

func (w *Window) Close() {
	w.mu.RLock()
	hwnd := w.hwnd
	w.mu.RUnlock()
	if hwnd != 0 {
		pPostMessage.Call(hwnd, wmClose, 0, 0)
	}
}

func (w *Window) run() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	className, _ := syscall.UTF16PtrFromString("AMonDashboardPopup")
	title, _ := syscall.UTF16PtrFromString("A-mon")
	instance, _, _ := pGetModuleHandle.Call(0)
	cursor, _, _ := pLoadCursor.Call(0, 32512)
	wc := wndClassEx{Size: uint32(unsafe.Sizeof(wndClassEx{})), Style: 3, WndProc: syscall.NewCallback(windowProc), Instance: instance, Cursor: cursor, ClassName: className}
	pRegisterClassEx.Call(uintptr(unsafe.Pointer(&wc)))
	const exStyle = 0x00000080 | 0x00000008 // WS_EX_TOOLWINDOW | WS_EX_TOPMOST
	const style = 0x80000000                // WS_POPUP
	hwnd, _, _ := pCreateWindowEx.Call(exStyle, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(title)), style, 0, 0, width, height, 0, 0, instance, 0)
	w.mu.Lock()
	w.hwnd = hwnd
	w.mu.Unlock()
	if hwnd != 0 {
		preference := int32(2) // DWMWCP_ROUND
		pDwmSetWindowAttribute.Call(hwnd, 33, uintptr(unsafe.Pointer(&preference)), unsafe.Sizeof(preference))
	}
	close(w.ready)
	var m msg
	for {
		ret, _, _ := pGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(ret) <= 0 {
			return
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
	}
}

func windowProc(hwnd uintptr, message uint32, wParam, lParam uintptr) uintptr {
	w := current
	if w == nil {
		ret, _, _ := pDefWindowProc.Call(hwnd, uintptr(message), wParam, lParam)
		return ret
	}
	switch message {
	case wmShow:
		w.mu.Lock()
		if w.visible {
			w.visible = false
			w.mu.Unlock()
			pShowWindow.Call(hwnd, 0)
			return 0
		}
		w.visible = true
		w.mu.Unlock()
		position(hwnd)
		pShowWindow.Call(hwnd, 5)
		pSetForegroundWindow.Call(hwnd)
		pInvalidateRect.Call(hwnd, 0, 1)
		return 0
	case wmRefresh:
		pInvalidateRect.Call(hwnd, 0, 1)
		return 0
	case wmSettings:
		pInvalidateRect.Call(hwnd, 0, 1)
		return 0
	case wmClose:
		pShowWindow.Call(hwnd, 0)
		pPostQuitMessage.Call(0)
		return 0
	case 0x0006: // WM_ACTIVATE
		if uint16(wParam) == 0 {
			w.mu.Lock()
			w.visible = false
			w.mu.Unlock()
			pShowWindow.Call(hwnd, 0)
		}
		return 0
	case 0x000F: // WM_PAINT
		paint(hwnd, w)
		return 0
	case 0x0014: // WM_ERASEBKGND
		return 1
	case 0x0202: // WM_LBUTTONUP
		x, y := int(int16(lParam)), int(int16(lParam>>16))
		w.mu.RLock()
		settingsView := w.settingsView
		w.mu.RUnlock()
		if settingsView {
			handleSettingsClick(hwnd, w, x, y)
			return 0
		}
		if x >= 440 {
			switch {
			case y >= 16 && y < 64:
			case y >= 76 && y < 124:
				signal(w.Sessions)
			case y >= 136 && y < 184:
				signal(w.Config)
			case y >= 476 && y < 528:
				signal(w.Quit)
			}
		} else if x >= 390 && x < 430 && y >= 12 && y < 48 {
			signal(w.Refresh)
		}
		return 0
	case 0x0100: // WM_KEYDOWN
		if wParam == 27 {
			w.mu.Lock()
			w.visible = false
			w.mu.Unlock()
			pShowWindow.Call(hwnd, 0)
		}
		return 0
	}
	ret, _, _ := pDefWindowProc.Call(hwnd, uintptr(message), wParam, lParam)
	return ret
}

func signal(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}

func handleSettingsClick(hwnd uintptr, w *Window, x, y int) {
	w.mu.Lock()
	if x >= 440 {
		switch {
		case y >= 16 && y < 64:
			w.settingsView = false
			w.mu.Unlock()
			pInvalidateRect.Call(hwnd, 0, 1)
			return
		case y >= 76 && y < 124:
			w.mu.Unlock()
			signal(w.Sessions)
			return
		case y >= 476 && y < 528:
			w.mu.Unlock()
			signal(w.Quit)
			return
		default:
			w.mu.Unlock()
			return
		}
	}
	switch {
	case y >= 82 && y < 145:
		w.settings.AutoUpdate = !w.settings.AutoUpdate
	case y >= 183 && y < 246:
		w.settings.AutomaticPaths = !w.settings.AutomaticPaths
	case y >= 270 && y < 333:
		w.settings.PetEnabled = !w.settings.PetEnabled
	case y >= 410 && y < 462:
		w.mu.Unlock()
		signal(w.Advanced)
		return
	case y >= height-58 && y <= height-12 && x < 216:
		w.settingsView = false
	case y >= height-58 && y <= height-12 && x >= 224 && x < 432:
		settings := w.settings
		w.settingsView = false
		w.mu.Unlock()
		select {
		case w.SaveSettings <- settings:
		default:
		}
		pInvalidateRect.Call(hwnd, 0, 1)
		return
	}
	w.mu.Unlock()
	pInvalidateRect.Call(hwnd, 0, 1)
}

func position(hwnd uintptr) {
	var cursor point
	pGetCursorPos.Call(uintptr(unsafe.Pointer(&cursor)))
	monitor, _, _ := pMonitorFromPoint.Call(uintptr(uint32(cursor.X))|uintptr(uint64(uint32(cursor.Y))<<32), 2)
	mi := monitorInfo{Size: uint32(unsafe.Sizeof(monitorInfo{}))}
	pGetMonitorInfo.Call(monitor, uintptr(unsafe.Pointer(&mi)))
	x := cursor.X - width + 24
	y := cursor.Y - height - 10
	if y < mi.Work.Top {
		y = cursor.Y + 14
	}
	if x < mi.Work.Left {
		x = mi.Work.Left + 8
	}
	if x+width > mi.Work.Right {
		x = mi.Work.Right - width - 8
	}
	pSetWindowPos.Call(hwnd, ^uintptr(0), uintptr(x), uintptr(y), width, height, 0x0040)
}

func paint(hwnd uintptr, w *Window) {
	var ps paintStruct
	hdc, _, _ := pBeginPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
	defer pEndPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
	var bounds rect
	pGetClientRect.Call(hwnd, uintptr(unsafe.Pointer(&bounds)))
	fill(hdc, bounds, rgb(28, 28, 36))
	w.mu.RLock()
	data := w.data
	settings := w.settings
	settingsView := w.settingsView
	w.mu.RUnlock()
	if settingsView {
		paintSettings(hdc, settings)
		return
	}

	fontTitle := font(-19, 600)
	defer pDeleteObject.Call(fontTitle)
	fontHero := font(-34, 700)
	defer pDeleteObject.Call(fontHero)
	fontBody := font(-14, 400)
	defer pDeleteObject.Call(fontBody)
	fontStrong := font(-14, 600)
	defer pDeleteObject.Call(fontStrong)
	fontSmall := font(-12, 400)
	defer pDeleteObject.Call(fontSmall)

	paintRail(hdc, fontBody, false)
	text(hdc, fontTitle, 18, 12, 220, 44, rgb(230, 230, 239), "A-mon", 0)
	status := data.Status
	if data.Active > 0 {
		status = "LIVE  " + status
	}
	text(hdc, fontSmall, 220, 15, 382, 42, rgb(154, 154, 176), status, 2)
	button(hdc, fontStrong, rect{390, 12, 430, 48}, "↻", false)

	rounded(hdc, rect{16, 56, 424, 140}, rgb(38, 38, 47), 10)
	text(hdc, fontSmall, 30, 67, 190, 88, rgb(154, 154, 176), "오늘 사용량", 0)
	text(hdc, fontHero, 28, 84, 250, 127, rgb(230, 230, 239), data.Today, 0)
	text(hdc, fontSmall, 260, 70, 408, 91, rgb(154, 154, 176), "전체 누적", 2)
	text(hdc, fontStrong, 260, 94, 408, 118, rgb(230, 230, 239), data.AllTime, 2)

	metrics := []struct{ label, value string }{{"입력", data.Input}, {"출력", data.Output}, {"캐시", data.Cache}}
	for i, m := range metrics {
		x := int32(16 + i*138)
		text(hdc, fontSmall, x, 148, x+124, 168, rgb(154, 154, 176), m.label, 0)
		text(hdc, fontStrong, x, 167, x+124, 190, rgb(230, 230, 239), m.value, 0)
	}

	if len(data.Providers) > 0 {
		paintProviderDashboard(hdc, fontBody, fontStrong, fontSmall, data)
	} else {
		paintLocalDashboard(hdc, fontBody, fontStrong, fontSmall, data)
	}
}

func paintProviderDashboard(hdc, fontBody, fontStrong, fontSmall uintptr, data Data) {
	text(hdc, fontStrong, 16, 199, 260, 221, rgb(230, 230, 239), "프로바이더 한도", 0)
	y := int32(224)
	for i, provider := range data.Providers {
		if i >= 2 {
			break
		}
		providerCard(hdc, fontStrong, fontSmall, y, provider)
		y += 56
	}

	localHeader, toolY, toolLimit := int32(339), int32(364), 2
	sessionHeader, sessionY, sessionLimit := int32(434), int32(458), 2
	if len(data.Providers) == 1 {
		localHeader, toolY, toolLimit = 283, 308, 3
		sessionHeader, sessionY, sessionLimit = 414, 438, 3
	}
	text(hdc, fontStrong, 16, localHeader, 220, localHeader+22, rgb(230, 230, 239), "로컬 사용량", 0)
	y = toolY
	for i, tool := range data.Tools {
		if i >= toolLimit {
			break
		}
		rounded(hdc, rect{16, y, 424, y + 31}, rgb(38, 38, 47), 8)
		text(hdc, fontBody, 28, y+5, 220, y+27, rgb(230, 230, 239), tool.Name, 0)
		text(hdc, fontSmall, 215, y+6, 412, y+26, rgb(154, 154, 176), tool.Today+"  /  "+tool.Total, 2)
		y += 33
	}

	text(hdc, fontStrong, 16, sessionHeader, 220, sessionHeader+22, rgb(230, 230, 239), "최근 세션", 0)
	paintSessions(hdc, fontBody, fontSmall, data.Sessions, sessionY, sessionLimit)
}

func paintLocalDashboard(hdc, fontBody, fontStrong, fontSmall uintptr, data Data) {
	text(hdc, fontStrong, 16, 199, 220, 221, rgb(230, 230, 239), "도구", 0)
	y := int32(224)
	for i, tool := range data.Tools {
		if i >= 5 {
			break
		}
		rounded(hdc, rect{16, y, 424, y + 31}, rgb(38, 38, 47), 8)
		text(hdc, fontBody, 28, y+5, 220, y+27, rgb(230, 230, 239), tool.Name, 0)
		text(hdc, fontSmall, 215, y+6, 412, y+26, rgb(154, 154, 176), tool.Today+"  /  "+tool.Total, 2)
		y += 33
	}

	text(hdc, fontStrong, 16, 394, 220, 416, rgb(230, 230, 239), "최근 세션", 0)
	paintSessions(hdc, fontBody, fontSmall, data.Sessions, 420, 3)
}

func providerCard(hdc, fontStrong, fontSmall uintptr, y int32, provider Provider) {
	rounded(hdc, rect{16, y, 424, y + 52}, rgb(38, 38, 47), 8)
	text(hdc, fontStrong, 28, y+3, 215, y+24, rgb(230, 230, 239), provider.Name, 0)
	text(hdc, fontSmall, 216, y+3, 412, y+24, rgb(154, 154, 176), provider.Plan, 2)
	if len(provider.Metrics) == 0 {
		text(hdc, fontSmall, 28, y+26, 412, y+47, rgb(154, 154, 176), provider.Status, 0)
		return
	}
	for i, metric := range provider.Metrics {
		if i >= 2 {
			break
		}
		x := int32(28 + i*194)
		label := metric.Label
		if metric.Reset != "" {
			label += " · " + metric.Reset
		}
		text(hdc, fontSmall, x, y+23, x+112, y+40, rgb(154, 154, 176), label, 0)
		text(hdc, fontSmall, x+104, y+23, x+182, y+40, rgb(230, 230, 239), metric.Remaining, 2)
		progressBar(hdc, rect{x, y + 43, x + 182, y + 47}, metric.Used)
	}
}

func progressBar(hdc uintptr, bounds rect, used float64) {
	rounded(hdc, bounds, rgb(58, 58, 74), 4)
	if used <= 0 {
		return
	}
	if used > 100 {
		used = 100
	}
	width := int32(float64(bounds.Right-bounds.Left) * used / 100)
	if width < 4 {
		width = 4
	}
	rounded(hdc, rect{bounds.Left, bounds.Top, bounds.Left + width, bounds.Bottom}, rgb(97, 97, 255), 4)
}

func paintSessions(hdc, fontBody, fontSmall uintptr, sessions []Session, y int32, limit int) {
	for i, session := range sessions {
		if i >= limit {
			break
		}
		if session.Active {
			rounded(hdc, rect{16, y + 5, 22, y + 11}, rgb(97, 97, 255), 6)
		}
		text(hdc, fontBody, 29, y, 270, y+22, rgb(230, 230, 239), session.Label, 0)
		text(hdc, fontSmall, 273, y+1, 424, y+21, rgb(154, 154, 176), session.Provider+"  "+session.Ended, 2)
		y += 25
	}
}

func paintSettings(hdc uintptr, settings Settings) {
	fontTitle := font(-19, 600)
	defer pDeleteObject.Call(fontTitle)
	fontBody := font(-14, 400)
	defer pDeleteObject.Call(fontBody)
	fontStrong := font(-14, 600)
	defer pDeleteObject.Call(fontStrong)
	fontSmall := font(-12, 400)
	defer pDeleteObject.Call(fontSmall)

	paintRail(hdc, fontBody, true)
	text(hdc, fontTitle, 18, 16, 220, 44, rgb(230, 230, 239), "설정", 0)
	text(hdc, fontSmall, 220, 19, 424, 42, rgb(154, 154, 176), "변경 후 저장", 2)

	text(hdc, fontStrong, 16, 57, 220, 78, rgb(230, 230, 239), "일반", 0)
	settingRow(hdc, fontStrong, fontSmall, 16, 82, "자동 업데이트", "새 버전을 자동으로 설치합니다", settings.AutoUpdate)
	text(hdc, fontStrong, 16, 158, 220, 179, rgb(230, 230, 239), "데이터 소스", 0)
	settingRow(hdc, fontStrong, fontSmall, 16, 183, "로그 경로 자동 감지", "Claude, Codex 등 기본 위치를 사용합니다", settings.AutomaticPaths)

	text(hdc, fontStrong, 16, 246, 220, 267, rgb(230, 230, 239), "Codex 펫", 0)
	settingRow(hdc, fontStrong, fontSmall, 16, 270, "데스크톱 펫 표시", "세부 기능과 펫 가져오기는 우클릭 메뉴에서 설정합니다", settings.PetEnabled)

	text(hdc, fontStrong, 16, 338, 220, 359, rgb(230, 230, 239), "서버 연결", 0)
	rounded(hdc, rect{16, 365, 424, 400}, rgb(38, 38, 47), 8)
	connection := "로컬 전용"
	connectionColor := rgb(154, 154, 176)
	if settings.ServerConnected {
		connection = "서버 연결됨"
		connectionColor = rgb(97, 97, 255)
	}
	text(hdc, fontBody, 28, 371, 412, 395, connectionColor, connection, 0)

	rounded(hdc, rect{16, 410, 424, 462}, rgb(38, 38, 47), 8)
	text(hdc, fontStrong, 28, 420, 250, 443, rgb(230, 230, 239), "고급 설정", 0)
	text(hdc, fontSmall, 235, 421, 412, 443, rgb(154, 154, 176), "서버 주소 · 개별 경로  >", 2)

	button(hdc, fontStrong, rect{16, height - 58, 216, height - 12}, "돌아가기", false)
	button(hdc, fontStrong, rect{224, height - 58, 424, height - 12}, "저장", true)
}

func settingRow(hdc, strong, small uintptr, x, y int32, title, description string, enabled bool) {
	rounded(hdc, rect{x, y, 424, y + 63}, rgb(38, 38, 47), 8)
	text(hdc, strong, x+12, y+9, 335, y+31, rgb(230, 230, 239), title, 0)
	text(hdc, small, x+12, y+32, 340, y+53, rgb(154, 154, 176), description, 0)
	toggle(hdc, 360, y+19, enabled)
}

func toggle(hdc uintptr, x, y int32, enabled bool) {
	track := rgb(58, 58, 74)
	knobX := x + 7
	if enabled {
		track = rgb(97, 97, 255)
		knobX = x + 27
	}
	rounded(hdc, rect{x, y, x + 48, y + 26}, track, 18)
	rounded(hdc, rect{knobX, y + 5, knobX + 16, y + 21}, rgb(255, 255, 255), 16)
}

func button(hdc, f uintptr, r rect, label string, primary bool) {
	color, fg := rgb(38, 38, 47), rgb(230, 230, 239)
	if primary {
		color, fg = rgb(97, 97, 255), rgb(255, 255, 255)
	}
	rounded(hdc, r, color, 10)
	text(hdc, f, r.Left, r.Top+13, r.Right, r.Bottom, fg, label, 1)
}

func paintRail(hdc, fontHandle uintptr, settings bool) {
	fill(hdc, rect{440, 0, width, height}, rgb(38, 38, 47))
	fill(hdc, rect{439, 0, 440, height}, rgb(58, 58, 74))
	railItem(hdc, fontHandle, rect{448, 16, 488, 56}, "⌂", !settings)
	railItem(hdc, fontHandle, rect{448, 76, 488, 116}, "≡", false)
	railItem(hdc, fontHandle, rect{448, 136, 488, 176}, "⚙", settings)
	railItem(hdc, fontHandle, rect{448, 480, 488, 520}, "×", false)
}

func railItem(hdc, fontHandle uintptr, r rect, label string, selected bool) {
	background := rgb(38, 38, 47)
	foreground := rgb(154, 154, 176)
	if selected {
		background = rgb(97, 97, 255)
		foreground = rgb(255, 255, 255)
	}
	rounded(hdc, r, background, 8)
	text(hdc, fontHandle, r.Left, r.Top+9, r.Right, r.Bottom, foreground, label, 1)
}

func rounded(hdc uintptr, r rect, color uint32, radius int32) {
	brush, _, _ := pCreateSolidBrush.Call(uintptr(color))
	defer pDeleteObject.Call(brush)
	pen, _, _ := pCreatePen.Call(0, 1, uintptr(color))
	defer pDeleteObject.Call(pen)
	oldBrush, _, _ := pSelectObject.Call(hdc, brush)
	oldPen, _, _ := pSelectObject.Call(hdc, pen)
	pRoundRect.Call(hdc, uintptr(r.Left), uintptr(r.Top), uintptr(r.Right), uintptr(r.Bottom), uintptr(radius), uintptr(radius))
	pSelectObject.Call(hdc, oldPen)
	pSelectObject.Call(hdc, oldBrush)
}

func fill(hdc uintptr, r rect, color uint32) {
	brush, _, _ := pCreateSolidBrush.Call(uintptr(color))
	defer pDeleteObject.Call(brush)
	pFillRect.Call(hdc, uintptr(unsafe.Pointer(&r)), brush)
}

func text(hdc, f uintptr, left, top, right, bottom int32, color uint32, value string, align uint32) {
	old, _, _ := pSelectObject.Call(hdc, f)
	defer pSelectObject.Call(hdc, old)
	pSetBkMode.Call(hdc, 1)
	pSetTextColor.Call(hdc, uintptr(color))
	p, _ := syscall.UTF16PtrFromString(value)
	r := rect{left, top, right, bottom}
	flags := uintptr(0x20 | 0x4 | align) // single line, vertically centered, alignment
	pDrawText.Call(hdc, uintptr(unsafe.Pointer(p)), ^uintptr(0), uintptr(unsafe.Pointer(&r)), flags)
}

func font(height int32, weight int32) uintptr {
	face, _ := syscall.UTF16PtrFromString("Segoe UI Variable Text")
	h, _, _ := pCreateFont.Call(uintptr(height), 0, 0, 0, uintptr(weight), 0, 0, 0, 1, 0, 0, 5, 0, uintptr(unsafe.Pointer(face)))
	return h
}

func rgb(r, g, b uint32) uint32 { return r | g<<8 | b<<16 }
