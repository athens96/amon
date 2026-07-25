//go:build windows

package pet

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	overlayWidth  = 382
	overlayHeight = 166

	wmPetRefresh = 0x8101
	wmPetClose   = 0x8102
	wmPetFrame   = 0x8103
)

type WindowSettings struct {
	Enabled              bool
	LocalActivityEnabled bool
	ShowsCurrentTask     bool
	SpritePath           string
	PositionX            *int
	PositionY            *int
}

type Position struct {
	X int
	Y int
}

// Window owns the always-on-top layered pet HWND and exposes only user intents.
// Session text remains in memory and is never sent through reporting code.
type Window struct {
	Dashboard      chan struct{}
	TogglePet      chan struct{}
	ToggleActivity chan struct{}
	ToggleTask     chan struct{}
	ImportPet      chan struct{}
	DownloadPets   chan struct{}
	Settings       chan struct{}
	Quit           chan struct{}
	Moved          chan Position

	mu                 sync.RWMutex
	presentations      []Presentation
	selectedIdentity   string
	settings           WindowSettings
	sprite             image.Image
	loadedSpritePath   string
	hwnd               uintptr
	visible            bool
	ready              chan struct{}
	done               chan struct{}
	dragging           bool
	dragMoved          bool
	dragStartCursor    point
	dragStartWindow    point
	lastRenderedStatus Status
	lastRenderedFrame  int
}

var currentWindow *Window

var (
	user32Pet               = syscall.NewLazyDLL("user32.dll")
	gdi32Pet                = syscall.NewLazyDLL("gdi32.dll")
	kernel32Pet             = syscall.NewLazyDLL("kernel32.dll")
	petRegisterClassEx      = user32Pet.NewProc("RegisterClassExW")
	petCreateWindowEx       = user32Pet.NewProc("CreateWindowExW")
	petDefWindowProc        = user32Pet.NewProc("DefWindowProcW")
	petGetMessage           = user32Pet.NewProc("GetMessageW")
	petTranslateMessage     = user32Pet.NewProc("TranslateMessage")
	petDispatchMessage      = user32Pet.NewProc("DispatchMessageW")
	petPostMessage          = user32Pet.NewProc("PostMessageW")
	petPostQuitMessage      = user32Pet.NewProc("PostQuitMessage")
	petDestroyWindow        = user32Pet.NewProc("DestroyWindow")
	petShowWindow           = user32Pet.NewProc("ShowWindow")
	petSetWindowPos         = user32Pet.NewProc("SetWindowPos")
	petGetWindowRect        = user32Pet.NewProc("GetWindowRect")
	petGetCursorPos         = user32Pet.NewProc("GetCursorPos")
	petSetCapture           = user32Pet.NewProc("SetCapture")
	petReleaseCapture       = user32Pet.NewProc("ReleaseCapture")
	petLoadCursor           = user32Pet.NewProc("LoadCursorW")
	petSystemParametersInfo = user32Pet.NewProc("SystemParametersInfoW")
	petMonitorFromRect      = user32Pet.NewProc("MonitorFromRect")
	petGetMonitorInfo       = user32Pet.NewProc("GetMonitorInfoW")
	petCreatePopupMenu      = user32Pet.NewProc("CreatePopupMenu")
	petAppendMenu           = user32Pet.NewProc("AppendMenuW")
	petTrackPopupMenu       = user32Pet.NewProc("TrackPopupMenu")
	petDestroyMenu          = user32Pet.NewProc("DestroyMenu")
	petSetForegroundWindow  = user32Pet.NewProc("SetForegroundWindow")
	petUpdateLayeredWindow  = user32Pet.NewProc("UpdateLayeredWindow")
	petGetDC                = user32Pet.NewProc("GetDC")
	petReleaseDC            = user32Pet.NewProc("ReleaseDC")
	petDrawText             = user32Pet.NewProc("DrawTextW")
	petCreateCompatibleDC   = gdi32Pet.NewProc("CreateCompatibleDC")
	petDeleteDC             = gdi32Pet.NewProc("DeleteDC")
	petCreateDIBSection     = gdi32Pet.NewProc("CreateDIBSection")
	petSelectObject         = gdi32Pet.NewProc("SelectObject")
	petDeleteObject         = gdi32Pet.NewProc("DeleteObject")
	petCreateSolidBrush     = gdi32Pet.NewProc("CreateSolidBrush")
	petCreatePen            = gdi32Pet.NewProc("CreatePen")
	petRoundRect            = gdi32Pet.NewProc("RoundRect")
	petCreateFont           = gdi32Pet.NewProc("CreateFontW")
	petSetTextColor         = gdi32Pet.NewProc("SetTextColor")
	petSetBkMode            = gdi32Pet.NewProc("SetBkMode")
	petGetModuleHandle      = kernel32Pet.NewProc("GetModuleHandleW")
)

type point struct{ X, Y int32 }
type size struct{ CX, CY int32 }
type rect struct{ Left, Top, Right, Bottom int32 }
type msg struct {
	Hwnd           uintptr
	Message        uint32
	WParam, LParam uintptr
	Time           uint32
	Pt             point
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
type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}
type bitmapInfo struct {
	Header bitmapInfoHeader
	Colors [1]uint32
}
type blendFunction struct {
	BlendOp             byte
	BlendFlags          byte
	SourceConstantAlpha byte
	AlphaFormat         byte
}
type monitorInfo struct {
	Size    uint32
	Monitor rect
	Work    rect
	Flags   uint32
}

func NewWindow(settings WindowSettings) *Window {
	w := &Window{
		Dashboard: make(chan struct{}, 1), TogglePet: make(chan struct{}, 1),
		ToggleActivity: make(chan struct{}, 1), ToggleTask: make(chan struct{}, 1),
		ImportPet: make(chan struct{}, 1), DownloadPets: make(chan struct{}, 1),
		Settings: make(chan struct{}, 1), Quit: make(chan struct{}, 1),
		Moved: make(chan Position, 1), ready: make(chan struct{}),
		done:     make(chan struct{}),
		settings: settings, lastRenderedFrame: -1,
	}
	w.loadSprite(settings.SpritePath)
	currentWindow = w
	go w.run()
	select {
	case <-w.ready:
	case <-time.After(2 * time.Second):
	}
	return w
}

func (w *Window) Update(presentations []Presentation, settings WindowSettings) {
	w.mu.Lock()
	previousIndex := CarouselIndex(w.selectedIdentity, w.presentations)
	w.presentations = append([]Presentation(nil), presentations...)
	w.selectedIdentity = PreservedIdentity(
		w.selectedIdentity,
		previousIndex,
		w.presentations,
	)
	spriteChanged := settings.SpritePath != w.loadedSpritePath
	w.settings = settings
	hwnd := w.hwnd
	w.mu.Unlock()
	if spriteChanged {
		w.loadSprite(settings.SpritePath)
	}
	if hwnd != 0 {
		petPostMessage.Call(hwnd, wmPetRefresh, 0, 0)
	}
}

func (w *Window) Close() {
	w.mu.RLock()
	hwnd := w.hwnd
	w.mu.RUnlock()
	if hwnd != 0 {
		petPostMessage.Call(hwnd, wmPetClose, 0, 0)
	}
}

func (w *Window) run() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer close(w.done)

	className, _ := syscall.UTF16PtrFromString("AMonPetOverlay")
	title, _ := syscall.UTF16PtrFromString("A-mon Pet")
	instance, _, _ := petGetModuleHandle.Call(0)
	cursor, _, _ := petLoadCursor.Call(0, 32512)
	wc := wndClassEx{
		Size: uint32(unsafe.Sizeof(wndClassEx{})), Style: 3,
		WndProc: syscall.NewCallback(petWindowProc), Instance: instance,
		Cursor: cursor, ClassName: className,
	}
	petRegisterClassEx.Call(uintptr(unsafe.Pointer(&wc)))
	const (
		wsPopup        = 0x80000000
		wsExLayered    = 0x00080000
		wsExToolWindow = 0x00000080
		wsExTopmost    = 0x00000008
		wsExNoActivate = 0x08000000
	)
	hwnd, _, _ := petCreateWindowEx.Call(
		wsExLayered|wsExToolWindow|wsExTopmost|wsExNoActivate,
		uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(title)),
		wsPopup, 0, 0, overlayWidth, overlayHeight, 0, 0, instance, 0,
	)
	w.mu.Lock()
	w.hwnd = hwnd
	w.placeInitial(hwnd)
	w.mu.Unlock()
	close(w.ready)
	if hwnd == 0 {
		return
	}
	w.render()
	w.applyVisibility()

	frameTicker := time.NewTicker(100 * time.Millisecond)
	defer frameTicker.Stop()
	go func() {
		for {
			select {
			case <-w.done:
				return
			case <-frameTicker.C:
				w.mu.RLock()
				h := w.hwnd
				w.mu.RUnlock()
				if h == 0 {
					return
				}
				petPostMessage.Call(h, wmPetFrame, 0, 0)
			}
		}
	}()

	var message msg
	for {
		result, _, _ := petGetMessage.Call(
			uintptr(unsafe.Pointer(&message)), 0, 0, 0,
		)
		if int32(result) <= 0 {
			return
		}
		petTranslateMessage.Call(uintptr(unsafe.Pointer(&message)))
		petDispatchMessage.Call(uintptr(unsafe.Pointer(&message)))
	}
}

func petWindowProc(hwnd uintptr, message uint32, wParam, lParam uintptr) uintptr {
	w := currentWindow
	if w == nil {
		result, _, _ := petDefWindowProc.Call(hwnd, uintptr(message), wParam, lParam)
		return result
	}
	switch message {
	case wmPetRefresh:
		w.applyVisibility()
		w.render()
		return 0
	case wmPetFrame:
		w.render()
		return 0
	case wmPetClose:
		petShowWindow.Call(hwnd, 0)
		w.mu.Lock()
		w.hwnd = 0
		w.mu.Unlock()
		if destroyed, _, _ := petDestroyWindow.Call(hwnd); destroyed == 0 {
			petPostQuitMessage.Call(0)
		}
		return 0
	case 0x0201: // WM_LBUTTONDOWN
		x, y := messagePoint(lParam)
		if x >= 242 && y >= 4 {
			var cursor point
			var bounds rect
			petGetCursorPos.Call(uintptr(unsafe.Pointer(&cursor)))
			petGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&bounds)))
			w.mu.Lock()
			w.dragging = true
			w.dragMoved = false
			w.dragStartCursor = cursor
			w.dragStartWindow = point{bounds.Left, bounds.Top}
			w.mu.Unlock()
			petSetCapture.Call(hwnd)
		}
		return 0
	case 0x0200: // WM_MOUSEMOVE
		w.mu.RLock()
		dragging := w.dragging
		startCursor, startWindow := w.dragStartCursor, w.dragStartWindow
		w.mu.RUnlock()
		if dragging && wParam&0x0001 != 0 {
			var cursor point
			petGetCursorPos.Call(uintptr(unsafe.Pointer(&cursor)))
			dx, dy := cursor.X-startCursor.X, cursor.Y-startCursor.Y
			if abs32(dx) > 3 || abs32(dy) > 3 {
				w.mu.Lock()
				w.dragMoved = true
				w.mu.Unlock()
				petSetWindowPos.Call(
					hwnd, ^uintptr(0), uintptr(int64(startWindow.X+dx)),
					uintptr(int64(startWindow.Y+dy)), overlayWidth, overlayHeight,
					0x0010|0x0004, // NOACTIVATE | NOZORDER
				)
			}
		}
		return 0
	case 0x0202: // WM_LBUTTONUP
		x, y := messagePoint(lParam)
		w.mu.Lock()
		wasDragging, moved := w.dragging, w.dragMoved
		w.dragging = false
		w.dragMoved = false
		w.mu.Unlock()
		if wasDragging {
			petReleaseCapture.Call()
			if moved {
				w.publishPosition(hwnd)
			} else if x >= 242 && y >= 4 {
				signal(w.Dashboard)
			}
			return 0
		}
		if y >= 8 && y <= 40 {
			switch {
			case x >= 164 && x < 190:
				w.moveSelection(-1)
			case x >= 208 && x < 234:
				w.moveSelection(1)
			}
		}
		return 0
	case 0x0205: // WM_RBUTTONUP
		w.showContextMenu(hwnd)
		return 0
	case 0x0002: // WM_DESTROY
		petPostQuitMessage.Call(0)
		return 0
	}
	result, _, _ := petDefWindowProc.Call(hwnd, uintptr(message), wParam, lParam)
	return result
}

func (w *Window) applyVisibility() {
	w.mu.Lock()
	shouldShow := w.settings.Enabled
	hwnd := w.hwnd
	w.visible = shouldShow
	w.mu.Unlock()
	if hwnd == 0 {
		return
	}
	if shouldShow {
		petShowWindow.Call(hwnd, 8) // SW_SHOWNA
	} else {
		petShowWindow.Call(hwnd, 0)
	}
}

func (w *Window) render() {
	w.mu.RLock()
	if w.hwnd == 0 || !w.visible {
		w.mu.RUnlock()
		return
	}
	hwnd := w.hwnd
	settings := w.settings
	presentations := append([]Presentation(nil), w.presentations...)
	selected := w.selectedIdentity
	sprite := w.sprite
	w.mu.RUnlock()

	presentation := Idle()
	index := 0
	if settings.LocalActivityEnabled && len(presentations) > 0 {
		index = CarouselIndex(selected, presentations)
		presentation = presentations[index]
	}
	frame := animationFrame(presentation.Status, time.Now())
	w.mu.Lock()
	w.lastRenderedStatus = presentation.Status
	w.lastRenderedFrame = frame
	w.mu.Unlock()

	screenDC, _, _ := petGetDC.Call(0)
	memoryDC, _, _ := petCreateCompatibleDC.Call(screenDC)
	defer petReleaseDC.Call(0, screenDC)
	defer petDeleteDC.Call(memoryDC)

	info := bitmapInfo{Header: bitmapInfoHeader{
		Size:  uint32(unsafe.Sizeof(bitmapInfoHeader{})),
		Width: overlayWidth, Height: -overlayHeight,
		Planes: 1, BitCount: 32,
	}}
	var bits unsafe.Pointer
	bitmap, _, _ := petCreateDIBSection.Call(
		memoryDC, uintptr(unsafe.Pointer(&info)), 0,
		uintptr(unsafe.Pointer(&bits)), 0, 0,
	)
	if bitmap == 0 || bits == nil {
		return
	}
	defer petDeleteObject.Call(bitmap)
	oldBitmap, _, _ := petSelectObject.Call(memoryDC, bitmap)
	defer petSelectObject.Call(memoryDC, oldBitmap)

	pixels := unsafe.Slice((*byte)(bits), overlayWidth*overlayHeight*4)
	clear(pixels)
	showBubble := settings.ShowsCurrentTask &&
		(!settings.LocalActivityEnabled || presentation.Status != StatusIdle)
	if showBubble {
		drawActivityBubble(memoryDC, presentation, settings, index, len(presentations))
		makeGDIAlphaOpaque(pixels, 4, 4, 238, 160)
	}
	if sprite != nil {
		drawSpriteFrame(pixels, sprite, presentation.Status, frame)
	} else {
		drawFallbackPet(pixels, presentation.Status, time.Now())
	}

	var destination rect
	petGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&destination)))
	dst := point{destination.Left, destination.Top}
	src := point{}
	dimensions := size{overlayWidth, overlayHeight}
	blend := blendFunction{
		BlendOp: 0, SourceConstantAlpha: 255, AlphaFormat: 1,
	}
	petUpdateLayeredWindow.Call(
		hwnd, screenDC, uintptr(unsafe.Pointer(&dst)),
		uintptr(unsafe.Pointer(&dimensions)), memoryDC,
		uintptr(unsafe.Pointer(&src)), 0,
		uintptr(unsafe.Pointer(&blend)), 2,
	)
}

func drawActivityBubble(
	hdc uintptr,
	p Presentation,
	settings WindowSettings,
	index, count int,
) {
	roundedRect(hdc, rect{4, 8, 234, 158}, rgb(29, 29, 38), 24)
	titleFont := createFont(-14, 600)
	bodyFont := createFont(-12, 400)
	smallFont := createFont(-11, 600)
	defer petDeleteObject.Call(titleFont)
	defer petDeleteObject.Call(bodyFont)
	defer petDeleteObject.Call(smallFont)

	if !settings.LocalActivityEnabled {
		drawText(hdc, titleFont, 17, 15, 218, 38, rgb(244, 164, 67), "●  작업 감지 꺼짐", 0)
		drawText(hdc, bodyFont, 17, 44, 218, 78, rgb(172, 172, 188), "우클릭 메뉴에서 현재 작업 감지를 켜세요.", 0)
		return
	}

	statusText, tint := statusLabel(p.Status)
	drawText(hdc, smallFont, 17, 14, 112, 34, tint, "●  "+statusText, 0)
	if count > 1 {
		drawText(hdc, smallFont, 164, 12, 187, 36, rgb(112, 112, 255), "‹", 1)
		drawText(hdc, smallFont, 187, 12, 211, 36, rgb(112, 112, 255), fmt.Sprintf("%d/%d", index+1, count), 1)
		drawText(hdc, smallFont, 210, 12, 233, 36, rgb(112, 112, 255), "›", 1)
	}
	drawText(hdc, titleFont, 17, 37, 218, 60, rgb(237, 237, 244), p.Title, 0)
	detail := p.Detail
	if detail == "" {
		detail = "입력 내용 없음"
	}
	output := p.Output
	if output == "" {
		if p.Status == StatusRunning {
			output = "응답 생성 중…"
		} else {
			output = "출력 내용 없음"
		}
	}
	drawText(hdc, bodyFont, 17, 63, 218, 84, rgb(169, 169, 186), "↓ 입력 · "+detail, 0)
	drawText(hdc, bodyFont, 17, 86, 218, 107, rgb(169, 169, 186), "↑ 출력 · "+output, 0)
	tokens := tokenSummary(p)
	if tokens != "" {
		drawText(hdc, smallFont, 17, 119, 218, 143, rgb(135, 135, 153), tokens, 0)
	}
}

func (w *Window) loadSprite(spritePath string) {
	var decoded image.Image
	if spritePath != "" {
		if file, err := os.Open(spritePath); err == nil {
			if candidate, err := png.Decode(file); err == nil &&
				candidate.Bounds().Dx() == RequiredWidth &&
				candidate.Bounds().Dy() == RequiredHeight {
				decoded = candidate
			}
			_ = file.Close()
		}
	}
	w.mu.Lock()
	w.sprite = decoded
	w.loadedSpritePath = spritePath
	w.mu.Unlock()
}

func drawSpriteFrame(
	pixels []byte,
	sheet image.Image,
	status Status,
	frame int,
) {
	row, count := animationStrip(status)
	if count == 0 {
		return
	}
	frame %= count
	sourceX, sourceY := frame*192, row*208
	const dstX, dstY, dstWidth, dstHeight = 248, 15, 126, 136
	for y := 0; y < dstHeight; y++ {
		sy := sourceY + y*208/dstHeight
		for x := 0; x < dstWidth; x++ {
			sx := sourceX + x*192/dstWidth
			c := color.NRGBAModel.Convert(sheet.At(sx, sy)).(color.NRGBA)
			if c.A == 0 {
				continue
			}
			setPixel(pixels, dstX+x, dstY+y, c)
		}
	}
}

func drawFallbackPet(pixels []byte, status Status, now time.Time) {
	_, tint := statusLabel(status)
	r := uint8(tint & 0xff)
	g := uint8((tint >> 8) & 0xff)
	b := uint8((tint >> 16) & 0xff)
	wave := math.Sin(float64(now.UnixMilli()) / 230)
	offsetY := 0
	if status == StatusRunning || status == StatusReady {
		offsetY = -int(math.Abs(wave) * 7)
	}
	cx, cy := 311, 65+offsetY
	drawCircle(pixels, cx, cy+48, 35, color.NRGBA{R: r, G: g, B: b, A: 235})
	drawCircle(pixels, cx-32, cy-35, 14, color.NRGBA{R: r, G: g, B: b, A: 255})
	drawCircle(pixels, cx+32, cy-35, 14, color.NRGBA{R: r, G: g, B: b, A: 255})
	drawCircle(pixels, cx, cy, 44, color.NRGBA{R: 245, G: 245, B: 250, A: 255})
	drawCircle(pixels, cx-15, cy-5, 5, color.NRGBA{R: 39, G: 39, B: 52, A: 255})
	drawCircle(pixels, cx+15, cy-5, 5, color.NRGBA{R: 39, G: 39, B: 52, A: 255})
	drawCircle(pixels, cx, cy+17, 4, color.NRGBA{R: r, G: g, B: b, A: 255})
	drawCircle(pixels, cx+38, cy+35, 8, color.NRGBA{R: r, G: g, B: b, A: 255})
}

func (w *Window) moveSelection(offset int) {
	w.mu.Lock()
	w.selectedIdentity = MovedIdentity(
		w.selectedIdentity, offset, w.presentations,
	)
	hwnd := w.hwnd
	w.mu.Unlock()
	if hwnd != 0 {
		petPostMessage.Call(hwnd, wmPetRefresh, 0, 0)
	}
}

func (w *Window) showContextMenu(hwnd uintptr) {
	menu, _, _ := petCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer petDestroyMenu.Call(menu)

	w.mu.RLock()
	settings := w.settings
	w.mu.RUnlock()
	type menuItem struct {
		id      uintptr
		label   string
		checked bool
	}
	items := []menuItem{
		{1001, "대시보드 열기", false},
		{1002, "펫 잠재우기", false},
		{1003, "현재 작업 감지", settings.LocalActivityEnabled},
		{1004, "작업 말풍선 표시", settings.ShowsCurrentTask},
		{1005, "Codex 펫 가져오기...", false},
		{1006, "Codex 펫 다운로드", false},
		{1007, "설정", false},
		{1008, "종료", false},
	}
	for _, item := range items {
		label, _ := syscall.UTF16PtrFromString(item.label)
		flags := uintptr(0)
		if item.checked {
			flags |= 0x00000008 // MF_CHECKED
		}
		petAppendMenu.Call(menu, flags, item.id, uintptr(unsafe.Pointer(label)))
	}
	var cursor point
	petGetCursorPos.Call(uintptr(unsafe.Pointer(&cursor)))
	petSetForegroundWindow.Call(hwnd)
	command, _, _ := petTrackPopupMenu.Call(
		menu, 0x0100|0x0002, uintptr(int64(cursor.X)), uintptr(int64(cursor.Y)),
		0, hwnd, 0,
	)
	switch command {
	case 1001:
		signal(w.Dashboard)
	case 1002:
		signal(w.TogglePet)
	case 1003:
		signal(w.ToggleActivity)
	case 1004:
		signal(w.ToggleTask)
	case 1005:
		signal(w.ImportPet)
	case 1006:
		signal(w.DownloadPets)
	case 1007:
		signal(w.Settings)
	case 1008:
		signal(w.Quit)
	}
}

func (w *Window) placeInitial(hwnd uintptr) {
	if hwnd == 0 {
		return
	}
	x, y := 0, 0
	if w.settings.PositionX != nil && w.settings.PositionY != nil {
		x, y = *w.settings.PositionX, *w.settings.PositionY
	} else {
		work := rect{}
		petSystemParametersInfo.Call(0x0030, 0, uintptr(unsafe.Pointer(&work)), 0)
		x = int(work.Right) - overlayWidth - 24
		y = int(work.Bottom) - overlayHeight - 24
	}
	x, y = constrainedPosition(x, y)
	petSetWindowPos.Call(
		hwnd, ^uintptr(0), uintptr(int64(x)), uintptr(int64(y)),
		overlayWidth, overlayHeight, 0x0010|0x0040,
	)
}

func (w *Window) publishPosition(hwnd uintptr) {
	var bounds rect
	petGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&bounds)))
	x, y := constrainedPosition(int(bounds.Left), int(bounds.Top))
	if x != int(bounds.Left) || y != int(bounds.Top) {
		petSetWindowPos.Call(
			hwnd, ^uintptr(0), uintptr(int64(x)), uintptr(int64(y)),
			overlayWidth, overlayHeight, 0x0010|0x0004,
		)
	}
	position := Position{X: x, Y: y}
	select {
	case w.Moved <- position:
	default:
	}
}

func constrainedPosition(x, y int) (int, int) {
	bounds := rect{
		Left: int32(x), Top: int32(y),
		Right: int32(x + overlayWidth), Bottom: int32(y + overlayHeight),
	}
	work := rect{}
	monitor, _, _ := petMonitorFromRect.Call(
		uintptr(unsafe.Pointer(&bounds)), 2, // MONITOR_DEFAULTTONEAREST
	)
	if monitor != 0 {
		info := monitorInfo{Size: uint32(unsafe.Sizeof(monitorInfo{}))}
		if ok, _, _ := petGetMonitorInfo.Call(
			monitor, uintptr(unsafe.Pointer(&info)),
		); ok != 0 {
			work = info.Work
		}
	}
	if work.Right <= work.Left || work.Bottom <= work.Top {
		petSystemParametersInfo.Call(0x0030, 0, uintptr(unsafe.Pointer(&work)), 0)
	}
	maxX := int(work.Right) - overlayWidth
	maxY := int(work.Bottom) - overlayHeight
	if maxX < int(work.Left) {
		maxX = int(work.Left)
	}
	if maxY < int(work.Top) {
		maxY = int(work.Top)
	}
	return clamp(x, int(work.Left), maxX), clamp(y, int(work.Top), maxY)
}

func animationStrip(status Status) (row, count int) {
	switch status {
	case StatusRunning:
		return 7, 6
	case StatusNeedsInput:
		return 6, 6
	case StatusReady:
		return 3, 4
	case StatusBlocked:
		return 5, 8
	default:
		return 0, 6
	}
}

func animationFrame(status Status, now time.Time) int {
	_, count := animationStrip(status)
	interval := int64(150)
	if status == StatusIdle {
		interval = 650
	}
	return int(now.UnixMilli()/interval) % count
}

func statusLabel(status Status) (string, uint32) {
	switch status {
	case StatusRunning:
		return "작업 중", rgb(97, 97, 255)
	case StatusNeedsInput:
		return "입력 필요", rgb(244, 164, 67)
	case StatusReady:
		return "완료", rgb(62, 196, 113)
	case StatusBlocked:
		return "문제 발생", rgb(235, 85, 96)
	default:
		return "대기 중", rgb(135, 135, 153)
	}
}

func tokenSummary(p Presentation) string {
	var values []string
	if p.InputTokens > 0 {
		values = append(values, "↓ 입력 "+compactTokens(p.InputTokens))
	}
	if p.OutputTokens > 0 {
		values = append(values, "↑ 출력 "+compactTokens(p.OutputTokens))
	}
	if len(values) == 0 && p.TotalTokens > 0 {
		values = append(values, "합계 "+compactTokens(p.TotalTokens))
	}
	return join(values, "   ")
}

func compactTokens(value int64) string {
	switch {
	case value >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(value)/1_000_000)
	case value >= 1_000:
		return fmt.Sprintf("%.1fK", float64(value)/1_000)
	default:
		return fmt.Sprintf("%d", value)
	}
}

func roundedRect(hdc uintptr, bounds rect, colour uint32, radius int32) {
	brush, _, _ := petCreateSolidBrush.Call(uintptr(colour))
	pen, _, _ := petCreatePen.Call(0, 1, uintptr(colour))
	defer petDeleteObject.Call(brush)
	defer petDeleteObject.Call(pen)
	oldBrush, _, _ := petSelectObject.Call(hdc, brush)
	oldPen, _, _ := petSelectObject.Call(hdc, pen)
	petRoundRect.Call(
		hdc, uintptr(bounds.Left), uintptr(bounds.Top),
		uintptr(bounds.Right), uintptr(bounds.Bottom),
		uintptr(radius), uintptr(radius),
	)
	petSelectObject.Call(hdc, oldPen)
	petSelectObject.Call(hdc, oldBrush)
}

func drawText(
	hdc, font uintptr,
	left, top, right, bottom int32,
	colour uint32,
	value string,
	align uint32,
) {
	old, _, _ := petSelectObject.Call(hdc, font)
	defer petSelectObject.Call(hdc, old)
	petSetBkMode.Call(hdc, 1)
	petSetTextColor.Call(hdc, uintptr(colour))
	text, _ := syscall.UTF16PtrFromString(value)
	bounds := rect{left, top, right, bottom}
	petDrawText.Call(
		hdc, uintptr(unsafe.Pointer(text)), ^uintptr(0),
		uintptr(unsafe.Pointer(&bounds)), uintptr(0x20|0x4|align|0x8000),
	)
}

func createFont(height int32, weight int32) uintptr {
	face, _ := syscall.UTF16PtrFromString("Segoe UI Variable Text")
	font, _, _ := petCreateFont.Call(
		uintptr(height), 0, 0, 0, uintptr(weight), 0, 0, 0,
		1, 0, 0, 5, 0, uintptr(unsafe.Pointer(face)),
	)
	return font
}

func makeGDIAlphaOpaque(pixels []byte, left, top, right, bottom int) {
	for y := top; y < bottom; y++ {
		for x := left; x < right; x++ {
			index := (y*overlayWidth + x) * 4
			if pixels[index] != 0 || pixels[index+1] != 0 || pixels[index+2] != 0 {
				pixels[index+3] = 255
			}
		}
	}
}

func drawCircle(pixels []byte, cx, cy, radius int, colour color.NRGBA) {
	for y := cy - radius; y <= cy+radius; y++ {
		for x := cx - radius; x <= cx+radius; x++ {
			dx, dy := x-cx, y-cy
			if dx*dx+dy*dy <= radius*radius {
				setPixel(pixels, x, y, colour)
			}
		}
	}
}

func setPixel(pixels []byte, x, y int, colour color.NRGBA) {
	if x < 0 || y < 0 || x >= overlayWidth || y >= overlayHeight {
		return
	}
	index := (y*overlayWidth + x) * 4
	alpha := uint16(colour.A)
	pixels[index] = byte(uint16(colour.B) * alpha / 255)
	pixels[index+1] = byte(uint16(colour.G) * alpha / 255)
	pixels[index+2] = byte(uint16(colour.R) * alpha / 255)
	pixels[index+3] = colour.A
}

func messagePoint(lParam uintptr) (int, int) {
	return int(int16(lParam)), int(int16(lParam >> 16))
}

func signal(channel chan struct{}) {
	select {
	case channel <- struct{}{}:
	default:
	}
}

func rgb(r, g, b uint32) uint32 { return r | g<<8 | b<<16 }

func abs32(value int32) int32 {
	if value < 0 {
		return -value
	}
	return value
}

func clamp(value, minimum, maximum int) int {
	if value < minimum {
		return minimum
	}
	if value > maximum {
		return maximum
	}
	return value
}

func join(values []string, separator string) string {
	if len(values) == 0 {
		return ""
	}
	result := values[0]
	for _, value := range values[1:] {
		result += separator + value
	}
	return result
}
