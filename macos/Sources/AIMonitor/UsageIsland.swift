import AppKit
import CoreText

/// Pure screen-coordinate geometry; no assumed notch width or display origin.
struct UsageIslandGeometry: Equatable {
    let frame: CGRect
    let gap: CGFloat
    let wingWidth: CGFloat

    static func make(screen: CGRect, safeTop: CGFloat, left: CGRect?, right: CGRect?) -> Self {
        guard isFinite(screen), !screen.isEmpty else {
            return Self(frame: .zero, gap: 0, wingWidth: 0)
        }
        let safeTop = safeTop.isFinite ? min(screen.height, max(0, safeTop)) : 0
        let notch = safeTop > 0
        let validAreas: Bool
        if let left, let right {
            validAreas = isFinite(left) && isFinite(right) && !left.isEmpty && !right.isEmpty
                && screen.contains(left) && screen.contains(right)
                && abs(left.maxY - screen.maxY) < 1 && abs(right.maxY - screen.maxY) < 1
                && right.minX > left.maxX
        } else { validAreas = false }
        // macOS may temporarily omit auxiliary areas during a display transition.
        // Reserve a conservative camera gap until the next screen notification.
        let gap = notch ? (validAreas ? right!.minX - left!.maxX : min(200, max(0, screen.width - 16))) : 0
        let center = notch && validAreas ? (left!.maxX + right!.minX) / 2 : screen.midX
        // Auxiliary regions can be asymmetric. Keep both wings on this display,
        // including narrow virtual displays, without moving text under the camera.
        let room = min(center - gap / 2 - screen.minX, screen.maxX - center - gap / 2)
        let wing = min(144, max(0, room - 8))
        let height = min(screen.height, max(32, safeTop))
        return Self(frame: CGRect(x: center - gap / 2 - wing, y: screen.maxY - height,
                                  width: wing * 2 + gap, height: height), gap: gap, wingWidth: wing)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}

struct UsageIslandItem: Equatable {
    let providerID: String
    let name: String
    let lines: [String]
    let detail: String
    /// 프로바이더 액센트(#rrggbb) — 아일랜드 아이콘 tint. 검정 배경이라 너무
    /// 어두운 색은 `UsageIslandSummary.iconColorHex` 가 흰색으로 대체한다.
    var accentHex: String = Palette.accentHex
    /// 이 프로바이더의 마지막 실제 사용 시각(라이브 세션 최신 updatedAt).
    /// 아일랜드는 최근 사용 순으로 2개만 보여준다. nil 은 "사용 기록 없음".
    var lastUsedAt: Date? = nil
}

struct UsageIslandSummary: Equatable {
    let items: [UsageIslandItem]
    let mode: String
    /// 아일랜드 두 날개에 올릴 항목 — 최근 사용한 프로바이더 2개.
    var visible: [UsageIslandItem] { Array(Self.recentFirst(items).prefix(2)) }
    var overflow: Int { max(0, items.count - 2) }

    /// 최근 사용 순 정렬(안정 정렬) — 사용 기록이 없는 항목은 원래 순서를
    /// 유지한 채 뒤로 간다. 순수 함수라 뷰 없이 검증한다.
    static func recentFirst(_ items: [UsageIslandItem]) -> [UsageIslandItem] {
        items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastUsedAt, rhs.element.lastUsedAt) {
            case let (l?, r?) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// 검정 아일랜드 위 아이콘 색 — 액센트가 너무 어두우면(상대 휘도 < 0.18,
    /// 예: Grok #111111) 흰색으로 대체해 항상 보이게 한다.
    static func iconColorHex(for accentHex: String) -> String {
        guard let color = Palette.nsColor(fromHex: accentHex)?.usingColorSpace(.sRGB) else {
            return "#ffffff"
        }
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
        return luminance < 0.18 ? "#ffffff" : accentHex
    }
    @MainActor
    static func line(for usage: LiveProvidersManager.MenuBarUsage, showingRemaining: Bool) -> String {
        let canShowRemaining: Bool
        if case .percent = usage.format { canShowRemaining = true }
        else { canShowRemaining = usage.limit > 0 }
        let mode = showingRemaining && canShowRemaining ? "남음" : "사용"
        return usage.menuBarText(showingRemaining: showingRemaining) + " " + mode
    }
    var tooltip: String {
        let detail = items.map(\.detail).joined(separator: "\n")
        return "amon · \(mode)\n" + (detail.isEmpty ? "사용량을 기다리는 중" : detail)
            + "\n클릭하여 상태창 열기 · 우클릭하여 설정"
    }
}

@MainActor
enum UsageIslandFonts {
    static let weights = ["Light", "Regular", "Medium", "SemiBold", "Bold"]

    static func resourceURL(weight: String) -> URL? {
        AIMonitorResources.url(forResource: "Poppins-\(weight)", withExtension: "ttf")
    }

    private static let registered: Void = {
        for weight in weights {
            // Installed .app bundles keep SwiftPM resources in Contents/Resources,
            // so use the same resolver as bundled pets rather than Bundle.module.
            if let url = resourceURL(weight: weight) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    static func font(_ size: CGFloat, weight: String = "Medium") -> NSFont {
        _ = registered
        return NSFont(name: "Poppins-\(weight)", size: size) ?? .systemFont(ofSize: size)
    }

    /// Preview/packaging verification must detect missing resources instead of
    /// silently validating a system-font fallback. The normal UI stays resilient.
    static func validateResources() throws {
        for weight in weights where resourceURL(weight: weight) == nil {
            throw ResourceError.missing("Poppins-\(weight).ttf")
        }
        guard AIMonitorResources.url(forResource: "OFL", withExtension: "txt") != nil else {
            throw ResourceError.missing("OFL.txt")
        }
        _ = registered
        for weight in weights where NSFont(name: "Poppins-\(weight)", size: 12) == nil {
            throw ResourceError.unavailableFont("Poppins-\(weight)")
        }
    }

    private enum ResourceError: LocalizedError {
        case missing(String)
        case unavailableFont(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): return "Island resource is missing from the application: \(name)"
            case .unavailableFont(let name): return "Island font could not be registered: \(name)"
            }
        }
    }
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One opaque hit region. Transparent rounded corners pass through to underlying apps.
@MainActor
final class UsageIslandView: NSView {
    var summary = UsageIslandSummary(items: [], mode: "사용") { didSet { refreshAccessibility(); needsDisplay = true } }
    var geometry = UsageIslandGeometry.make(screen: .zero, safeTop: 0, left: nil, right: nil)
    var onOpen: ((NSView) -> Void)?
    var onClose: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    var isOpen: () -> Bool = { false }
    var onSetOpen: ((Bool, NSView) -> Void)?
    private var mouseShouldOpen: Bool?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refreshAccessibility()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        refreshAccessibility()
    }

    private var shape: NSBezierPath {
        Self.shape(in: bounds, notched: geometry.gap > 0)
    }
    static func shape(in bounds: CGRect, notched: Bool) -> NSBezierPath {
        let radius = min(14, max(0, min(bounds.width, bounds.height) / 2))
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if notched {
            // Flat screen edge, rounded lower corners; the physical camera is in the gap.
            path.appendRect(CGRect(x: bounds.minX, y: bounds.maxY - radius, width: bounds.width, height: radius))
        }
        return path
    }
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        return shape.contains(convert(window.convertPoint(fromScreen: point), from: nil))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && shape.contains(convert(point, from: superview)) ? self : nil
    }
    private func refreshAccessibility() {
        toolTip = summary.tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(summary.tooltip)
        setAccessibilityHelp("Return 또는 Space로 amon 상태창 열기 · Shift-F10으로 설정 메뉴 열기")
    }
    override func accessibilityPerformPress() -> Bool {
        if let onSetOpen { onSetOpen(!isOpen(), self); return true }
        guard let onOpen else { return false }
        onOpen(self)
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = makeMenu?() else { return false }
        return menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.minY), in: self)
    }
    override func mouseUp(with event: NSEvent) {
        let shouldOpen = mouseShouldOpen ?? !isOpen()
        mouseShouldOpen = nil
        guard shape.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let onSetOpen { onSetOpen(shouldOpen, self) }
        else { onOpen?(self) }
    }
    override func mouseDown(with event: NSEvent) {
        prepareMousePress()
    }
    // The controller also captures at the local event monitor, before native
    // transient-popover dismissal changes isOpen during mouseDown delivery.
    func prepareMousePress() {
        if mouseShouldOpen == nil { mouseShouldOpen = !isOpen() }
    }
    func cancelMousePress() {
        mouseShouldOpen = nil
    }
    override func rightMouseUp(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76:
            if !event.isARepeat { _ = accessibilityPerformPress() }
        case 53: cancelMousePress(); onClose?()
        case 109 where event.modifierFlags.contains(.shift): _ = accessibilityPerformShowMenu()
        default: super.keyDown(with: event)
        }
    }
    /// 노치를 축으로 한 거울 레이아웃 — 왼쪽 날개는 `사용량 · 아이콘`(아이콘이
    /// 노치 쪽), 오른쪽 날개는 `아이콘 · 사용량`. 텍스트는 아이콘 반대편으로 정렬.
    struct SlotLayout: Equatable {
        let icon: CGRect
        let text: CGRect
        let alignment: NSTextAlignment
    }
    static let iconSize: CGFloat = 16
    static let iconTextGap: CGFloat = 6
    static func slotLayout(in rect: CGRect, slot: Int) -> SlotLayout {
        let size = min(iconSize, max(0, min(rect.width, rect.height)))
        let iconY = rect.minY + (rect.height - size) / 2
        if slot == 0 {
            let icon = CGRect(x: rect.maxX - size, y: iconY, width: size, height: size)
            let text = CGRect(x: rect.minX, y: rect.minY, width: max(0, icon.minX - iconTextGap - rect.minX),
                              height: rect.height)
            return SlotLayout(icon: icon, text: text, alignment: .right)
        }
        let icon = CGRect(x: rect.minX, y: iconY, width: size, height: size)
        let text = CGRect(x: min(rect.maxX, icon.maxX + iconTextGap), y: rect.minY,
                          width: max(0, rect.maxX - icon.maxX - iconTextGap), height: rect.height)
        return SlotLayout(icon: icon, text: text, alignment: .left)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        NSColor.black.setFill()
        shape.fill()
        let visible = summary.visible
        for slot in 0..<2 {
            let x = slot == 0 ? CGFloat(0) : geometry.wingWidth + geometry.gap
            let inset = min(12, geometry.wingWidth / 2)
            let rect = CGRect(x: x + inset, y: 0, width: max(0, geometry.wingWidth - inset * 2), height: bounds.height)
            if slot < visible.count {
                draw(visible[slot], in: rect, slot: slot, overflow: slot == 1 ? summary.overflow : 0)
            } else {
                drawText(slot == 0 ? "amon" : (visible.isEmpty ? "사용량 대기" : summary.mode),
                         in: rect, size: 11, color: .white, alignment: slot == 0 ? .right : .left)
            }
        }
        if window?.firstResponder === self, window?.isKeyWindow == true {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = Self.shape(in: bounds.insetBy(dx: 1, dy: 1), notched: geometry.gap > 0)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
    private func draw(_ item: UsageIslandItem, in rect: CGRect, slot: Int, overflow: Int) {
        let layout = Self.slotLayout(in: rect, slot: slot)
        let tint = UsageIslandSummary.iconColorHex(for: item.accentHex)
        if let icon = ProviderIcons.coloredMenuBarImage(id: item.providerID, colorHex: tint) {
            icon.draw(in: layout.icon)
        } else {
            drawText(String(item.name.prefix(1)), in: layout.icon, size: 11,
                     color: Palette.nsColor(fromHex: tint) ?? .white, alignment: .center)
        }
        let textRect = layout.text
        let lines = Array(item.lines.prefix(2))
        if lines.count > 1 {
            let blockY = max(0, (rect.height - 32) / 2)
            for (index, line) in lines.enumerated() {
                let suffix = index == 0 && overflow > 0 ? " +\(overflow)" : ""
                drawText(line + suffix, in: CGRect(x: textRect.minX, y: blockY + (index == 0 ? 14 : 0),
                         width: textRect.width, height: 18), size: 10, color: .white,
                         alignment: layout.alignment)
            }
        } else {
            drawText((lines.first ?? "—") + (overflow > 0 ? " +\(overflow)" : ""), in: textRect, size: 12,
                     color: .white, alignment: layout.alignment)
        }
    }
    private func drawText(_ value: String, in rect: CGRect, size: CGFloat, color: NSColor,
                          alignment: NSTextAlignment = .left) {
        guard rect.width > 0, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: UsageIslandFonts.font(size), .foregroundColor: color,
                                                        .paragraphStyle: paragraph]
        let text = value as NSString
        let height = text.size(withAttributes: attributes).height
        text.draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                  withAttributes: attributes)
    }
}

/// Observes existing snapshots only. No scanner, provider refresh, or network work.
@MainActor
final class UsageIslandController {
    let view = UsageIslandView()
    private let panel: IslandPanel
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var enabled = false
    private var sleeping = false
    private var stopped = false
    var onGeometryChange: (() -> Void)?
    var anchor: NSView? { !stopped && enabled && panel.isVisible ? view : nil }

    init(onOpen: @escaping (NSView) -> Void, onClose: @escaping () -> Void, makeMenu: @escaping () -> NSMenu,
         isOpen: @escaping () -> Bool = { false }, onSetOpen: ((Bool, NSView) -> Void)? = nil) {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
        view.onOpen = onOpen
        view.onClose = onClose
        view.makeMenu = makeMenu
        view.isOpen = isOpen
        view.onSetOpen = onSetOpen
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reposition() } })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] note in
                    Task { @MainActor in
                        guard let self, !self.stopped else { return }
                        if note.name == NSWorkspace.willSleepNotification { self.sleeping = true }
                        if note.name == NSWorkspace.didWakeNotification { self.sleeping = false }
                        self.reposition()
                    }
                })
        }
    }
    private func startMouseMonitors() {
        guard localMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateMousePassthrough()
                if event.type == .leftMouseDown {
                    if self.containsScreenPoint(NSEvent.mouseLocation) { self.view.prepareMousePress() }
                    else { self.view.cancelMousePress() }
                }
            }
            return event
        }
    }
    private func stopMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil; globalMouseMonitor = nil
        view.cancelMousePress()
    }
    func update(summary: UsageIslandSummary, enabled: Bool) {
        guard !stopped else { return }
        // 세션 폴링마다 불리므로 내용이 같으면 다시 그리지 않는다.
        if view.summary != summary { view.summary = summary }
        if self.enabled != enabled { self.enabled = enabled; reposition() }
    }
    private func updateMousePassthrough() {
        panel.ignoresMouseEvents = !containsScreenPoint(NSEvent.mouseLocation)
    }
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        anchor != nil && view.containsScreenPoint(point)
    }
    private func reposition() {
        guard !stopped else { return }
        onGeometryChange?()
        guard enabled, !sleeping,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
        else { panel.orderOut(nil); stopMouseMonitors(); return }
        view.geometry = .make(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                              left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        panel.setFrame(view.geometry.frame, display: true)
        view.frame = CGRect(origin: .zero, size: view.geometry.frame.size)
        panel.orderFrontRegardless()
        startMouseMonitors()
        updateMousePassthrough()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        enabled = false
        onGeometryChange?()
        panel.orderOut(nil)
        stopMouseMonitors()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        observers.removeAll(); workspaceObservers.removeAll()
        onGeometryChange = nil
        view.onOpen = nil; view.onClose = nil; view.makeMenu = nil; view.onSetOpen = nil
        view.isOpen = { false }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        let panel = panel
        let localMonitor = localMouseMonitor
        let globalMonitor = globalMouseMonitor
        // stop() is the normal main-actor teardown. An unexpected owner release
        // still removes event monitors and the window without retaining self.
        DispatchQueue.main.async {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            panel.orderOut(nil)
        }
    }
}

/// Synthetic panel only: never constructs AppState, scans disk, reads credentials, or connects.
@MainActor
enum UsageIslandPreview {
    private static var controller: UsageIslandController?
    private static var popover: NSPopover?
    private static let popoverDelegate = PreviewPopoverDelegate()
    private final class PreviewPopoverDelegate: NSObject, NSPopoverDelegate {
        func popoverShouldClose(_ popover: NSPopover) -> Bool {
            !(NSApp.currentEvent?.type == .leftMouseDown
              && controller?.containsScreenPoint(NSEvent.mouseLocation) == true)
        }
    }
    private enum RenderError: Error { case bitmapUnavailable, pngUnavailable }
    static let sample = UsageIslandSummary(items: [
        .init(providerID: "claude", name: "Claude", lines: ["42% 사용"], detail: "Claude Session · 42% 사용",
              accentHex: Palette.hexClaude, lastUsedAt: Date(timeIntervalSince1970: 1_000)),
        .init(providerID: "codex", name: "Codex", lines: ["18% 사용"], detail: "Codex Session · 18% 사용",
              accentHex: Palette.hexCodex, lastUsedAt: Date(timeIntervalSince1970: 2_000)),
        .init(providerID: "grok", name: "Grok", lines: ["5% 사용"], detail: "Grok Session · 5% 사용",
              accentHex: Palette.hexGrok, lastUsedAt: nil)
    ], mode: "사용")

    /// Offscreen production view rendering, with no windows or application services.
    static func render(directory: String) throws {
        _ = NSApplication.shared
        try UsageIslandFonts.validateResources()
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let twoLines = UsageIslandSummary(items: [
            .init(providerID: "claude", name: "Claude", lines: ["58% 남음", "82% 남음"],
                  detail: "Claude · Session 58% 남음 · Week 82% 남음", accentHex: Palette.hexClaude),
            .init(providerID: "openrouter", name: "OpenRouter", lines: ["$4.20 사용"],
                  detail: "OpenRouter · Total usage $4.20 사용", accentHex: Palette.hexOpenRouter)
        ], mode: "남음")
        let variants: [(name: String, notched: Bool, summary: UsageIslandSummary)] = [
            ("island-pill", false, sample), ("island-notch", true, sample),
            ("island-notch-two-lines", true, twoLines),
            ("island-pill-empty", false, .init(items: [], mode: "사용"))
        ]
        for variant in variants {
            let notched = variant.notched
            let layout = UsageIslandGeometry.make(
                screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: notched ? 38 : 0,
                left: notched ? CGRect(x: 0, y: 944, width: 650, height: 38) : nil,
                right: notched ? CGRect(x: 862, y: 944, width: 650, height: 38) : nil)
            let view = UsageIslandView(frame: CGRect(origin: .zero, size: layout.frame.size))
            view.geometry = layout
            view.summary = variant.summary
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(layout.frame.width * 2),
                pixelsHigh: Int(layout.frame.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep)
            else { throw RenderError.bitmapUnavailable }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let scale = NSAffineTransform(); scale.scale(by: 2); scale.concat()
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let target = destination.appendingPathComponent(variant.name + ".png")
            guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError.pngUnavailable }
            try data.write(to: target)
            print(target.path)
        }
    }
    static func run(smoke: Bool = false) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        controller = UsageIslandController(onOpen: { view in
            setOpen(popover?.isShown != true, anchor: view)
        }, onClose: { popover?.performClose(nil) }, makeMenu: {
            let menu = NSMenu()
            menu.addItem(withTitle: "미리보기 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return menu
        }, isOpen: { popover?.isShown == true }, onSetOpen: { shown, anchor in
            setOpen(shown, anchor: anchor)
        })
        controller?.update(summary: sample, enabled: true)
        if smoke {
            // Exercise a real NSPanel anchor and transient NSPopover with synthetic
            // mouse input, plus accessibility and disable/stop, without AppState.
            DispatchQueue.main.async {
                let firstClick = click() && popover?.isShown == true
                let secondClick = click() && popover?.isShown == false
                _ = controller?.view.accessibilityPerformPress()
                let opened = popover?.isShown == true
                _ = controller?.view.accessibilityPerformPress()
                let closed = popover?.isShown == false
                controller?.update(summary: sample, enabled: false)
                let disabled = controller?.anchor == nil
                controller?.update(summary: sample, enabled: true)
                let reenabled = controller?.anchor != nil
                controller?.stop()
                controller?.update(summary: sample, enabled: true)
                let stopped = controller?.anchor == nil
                print("Island native popover smoke: firstClick=\(firstClick), secondClick=\(secondClick), opened=\(opened), closed=\(closed), disabled=\(disabled), reenabled=\(reenabled), stopped=\(stopped)")
                exit(firstClick && secondClick && opened && closed && disabled && reenabled && stopped ? 0 : 1)
            }
        }
        app.run()
        controller?.stop()
    }

    private static func setOpen(_ shown: Bool, anchor: NSView) {
        guard shown else { popover?.performClose(nil); return }
        guard popover?.isShown != true else { return }
        let preview = NSPopover()
        preview.behavior = .transient
        preview.animates = false
        preview.delegate = popoverDelegate
        let content = NSViewController()
        let label = NSTextField(labelWithString: "amon · 아일랜드 미리보기\n실제 실행에서는 기존 상태창이 열립니다.")
        label.font = UsageIslandFonts.font(14)
        label.frame = CGRect(x: 24, y: 24, width: 340, height: 60)
        content.view = NSView(frame: CGRect(x: 0, y: 0, width: 388, height: 108))
        content.view.addSubview(label)
        preview.contentViewController = content
        popover = preview
        NSApp.activate(ignoringOtherApps: true)
        preview.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private static func click() -> Bool {
        guard let view = controller?.anchor, let window = view.window else { return false }
        let point = view.convert(NSPoint(x: 30, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { return false }
            window.sendEvent(event)
        }
        return true
    }
}
