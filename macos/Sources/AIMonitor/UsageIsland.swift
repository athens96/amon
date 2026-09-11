import AppKit
import CoreText

/// Pure screen-coordinate geometry; no assumed notch width or display origin.
struct UsageIslandGeometry: Equatable {
    let frame: CGRect
    let gap: CGFloat
    let leftWing: CGFloat
    let rightWing: CGFloat
    var wingWidth: CGFloat { leftWing }

    static let minimumWing: CGFloat = 44
    static let pillCenterGap: CGFloat = 28
    static let maximumScale: CGFloat = 1.07
    /// Two blur radii plus the outer stroke; transparent pixels never receive hits.
    static let glowOutset: CGFloat = 29
    static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        height.isFinite ? max(0, height / 2) : 0
    }
    var horizontalOutset: CGFloat { ceil(frame.width * (Self.maximumScale - 1) / 2 + Self.glowOutset) }
    var verticalOutset: CGFloat { ceil(frame.height * (Self.maximumScale - 1) + Self.glowOutset) }
    var panelFrame: CGRect {
        frame.isEmpty ? .zero : frame.insetBy(dx: -horizontalOutset, dy: -verticalOutset)
    }
    /// Base visible shape in panel-local coordinates, stable while pressing.
    var islandRect: CGRect {
        frame.isEmpty ? .zero : CGRect(x: horizontalOutset, y: verticalOutset, width: frame.width, height: frame.height)
    }

    static func make(screen: CGRect, safeTop: CGFloat, left: CGRect?, right: CGRect?,
                     wings: (left: CGFloat, right: CGFloat)? = nil) -> Self {
        guard isFinite(screen), !screen.isEmpty else {
            return Self(frame: .zero, gap: 0, leftWing: 0, rightWing: 0)
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
        let gap = notch ? (validAreas ? right!.minX - left!.maxX : min(200, max(0, screen.width - 16)))
            : min(Self.pillCenterGap, max(0, screen.width - 16))
        let center = notch && validAreas ? (left!.maxX + right!.minX) / 2 : screen.midX
        // Auxiliary regions can be asymmetric. Keep both wings on this display,
        // including narrow virtual displays, without moving text under the camera.
        let leftRoom = max(0, center - gap / 2 - screen.minX - 8)
        let rightRoom = max(0, screen.maxX - center - gap / 2 - 8)
        let room = min(leftRoom, rightRoom)
        let fallback = min(144, room)
        func finiteWidth(_ requested: CGFloat) -> CGFloat {
            requested.isFinite ? ceil(requested) : fallback
        }
        // Match the wider measured slot while preserving camera-centered symmetry.
        // The more constrained physical side bounds both wings on asymmetric displays.
        let wing = wings.map { min(room, max(Self.minimumWing, finiteWidth($0.left), finiteWidth($0.right))) } ?? fallback
        let height = min(screen.height, max(32, safeTop))
        return Self(frame: CGRect(x: center - gap / 2 - wing, y: screen.maxY - height,
                                  width: wing * 2 + gap, height: height),
                    gap: gap, leftWing: wing, rightWing: wing)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}

/// Snapshot of existing display geometry; injectable for deterministic layout checks.
struct UsageIslandScreen: Equatable {
    let frame: CGRect
    let safeTop: CGFloat
    var left: CGRect? = nil
    var right: CGRect? = nil

    static func preferred(in screens: [Self], mainFrame: CGRect?) -> Self? {
        if let mainFrame, let screen = screens.first(where: { $0.frame == mainFrame }) { return screen }
        return screens.first(where: { $0.safeTop.isFinite && $0.safeTop > 0 }) ?? screens.first
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
        usage.menuBarText(showingRemaining: showingRemaining)
    }
    /// Semantic labels stay in the tooltip; unbounded amounts always mean usage.
    @MainActor
    static func modeLabel(for usage: LiveProvidersManager.MenuBarUsage, showingRemaining: Bool) -> String {
        let canShowRemaining: Bool
        if case .percent = usage.format { canShowRemaining = true }
        else { canShowRemaining = usage.limit > 0 }
        return showingRemaining && canShowRemaining ? "남음" : "사용"
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
    // The transparent top margin belongs above the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One opaque hit region. Transparent rounded corners pass through to underlying apps.
@MainActor
final class UsageIslandView: NSView {
    var summary = UsageIslandSummary(items: [], mode: "사용") { didSet { refreshAccessibility(); needsDisplay = true } }
    var geometry = UsageIslandGeometry.make(screen: .zero, safeTop: 0, left: nil, right: nil) { didSet { needsDisplay = true } }
    var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            if !hovered { cancelScaleAnimation() }
        }
    }
    var reduceMotion = false {
        didSet { if reduceMotion { cancelScaleAnimation() } }
    }
    private(set) var scale: CGFloat = 1 { didSet { if scale != oldValue { needsDisplay = true } } }
    private var scaleTimer: Timer?
    var isAnimatingScale: Bool { scaleTimer?.isValid == true }
    static let horizontalPadding: CGFloat = 8
    static let pressedScale = UsageIslandGeometry.maximumScale
    static let animationDuration: TimeInterval = 0.15
    static let neonBlurRadius: CGFloat = 14
    static let neon = Palette.nsColor(fromHex: Palette.accentHex) ?? .systemPink
    var popoverAnchorRect: CGRect { geometry.frame.isEmpty ? bounds : geometry.islandRect }
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
        Self.shape(in: Self.visualRect(islandRect: popoverAnchorRect, scale: scale))
    }
    /// One contour avoids an internal horizontal stroke under hover/focus effects.
    /// Both display types attach a flat top edge to the screen edge.
    static func shape(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        guard !rect.isEmpty else { return path }
        let radius = min(UsageIslandGeometry.cornerRadius(forHeight: rect.height), rect.width / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.appendArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                       startAngle: 0, endAngle: -90, clockwise: true)
        path.line(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.appendArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                       startAngle: -90, endAngle: -180, clockwise: true)
        path.close()
        return path
    }
    static func shape(in bounds: CGRect, notched: Bool) -> NSBezierPath { shape(in: bounds) }

    static func visualTransform(islandRect rect: CGRect, scale: CGFloat) -> AffineTransform {
        let scale = scale.isFinite ? max(1, min(pressedScale, scale)) : 1
        var transform = AffineTransform(translationByX: rect.midX, byY: rect.maxY)
        transform.scale(scale)
        transform.translate(x: -rect.midX, y: -rect.maxY)
        return transform
    }
    static func visualRect(islandRect rect: CGRect, scale: CGFloat) -> CGRect {
        let transform = visualTransform(islandRect: rect, scale: scale)
        let origin = transform.transform(rect.origin)
        let corner = transform.transform(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
    }
    static func contentWidth(lines: [String], hasIcon: Bool, size: CGFloat) -> CGFloat {
        let widest = lines.map { ($0 as NSString).size(withAttributes: [.font: UsageIslandFonts.font(size)]).width }.max() ?? 0
        return ceil(widest + (hasIcon ? iconSize + iconTextGap : 0) + horizontalPadding * 2)
    }
    func fittedWings() -> (left: CGFloat, right: CGFloat) {
        let visible = summary.visible
        func width(slot: Int) -> CGFloat {
            guard slot < visible.count else {
                let placeholder = slot == 0 ? "amon" : (visible.isEmpty ? "사용량 대기" : "")
                return Self.contentWidth(lines: [placeholder], hasIcon: false, size: 11)
            }
            var lines = Array(visible[slot].lines.prefix(2))
            if lines.isEmpty { lines = ["—"] }
            if slot == 1, summary.overflow > 0 { lines[0] += " +\(summary.overflow)" }
            return Self.contentWidth(lines: lines, hasIcon: true, size: lines.count > 1 ? 10 : 12)
        }
        return (width(slot: 0), width(slot: 1))
    }
    static func animationScale(from start: CGFloat, to target: CGFloat, elapsed: TimeInterval) -> CGFloat {
        let progress = elapsed.isFinite ? max(0, min(1, elapsed / animationDuration)) : 1
        let eased = 1 - pow(1 - progress, 3)
        return start + (target - start) * eased
    }
    func setScaleForPreview(_ value: CGFloat) {
        cancelScaleAnimation()
        scale = reduceMotion || !value.isFinite ? 1 : min(Self.pressedScale, max(1, value))
    }
    private func animateScale(to target: CGFloat) {
        scaleTimer?.invalidate(); scaleTimer = nil
        guard !reduceMotion else { scale = 1; return }
        guard abs(scale - target) > 0.00001 else { scale = target; return }
        let start = scale
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.scaleTimer === timer else { timer.invalidate(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                self.scale = Self.animationScale(from: start, to: target, elapsed: elapsed)
                if elapsed >= Self.animationDuration { timer.invalidate(); self.scaleTimer = nil }
            }
        }
        scaleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func cancelScaleAnimation() {
        scaleTimer?.invalidate(); scaleTimer = nil
        scale = 1
    }
    func resetInteraction() {
        cancelMousePress()
        cancelScaleAnimation()
        hovered = false
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { resetInteraction() }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit { scaleTimer?.invalidate() }
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
        return menu.popUp(positioning: nil, at: NSPoint(x: popoverAnchorRect.midX, y: popoverAnchorRect.minY), in: self)
    }
    override func mouseUp(with event: NSEvent) {
        let shouldOpen = mouseShouldOpen
        mouseShouldOpen = nil
        let inside = shape.contains(convert(event.locationInWindow, from: nil))
        animateScale(to: 1)
        guard inside, let shouldOpen else { return }
        if let onSetOpen { onSetOpen(shouldOpen, self) }
        else { onOpen?(self) }
    }
    override func mouseDown(with event: NSEvent) {
        prepareMousePress()
        animateScale(to: Self.pressedScale)
    }
    override func mouseExited(with event: NSEvent) { hovered = false; cancelScaleAnimation() }
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
        case 53: resetInteraction(); onClose?()
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
        let island = popoverAnchorRect
        let outline = shape
        if hovered {
            NSGraphicsContext.saveGraphicsState()
            for (blur, alpha) in [(Self.neonBlurRadius, CGFloat(0.9)), (CGFloat(5), CGFloat(1))] {
                let glow = NSShadow()
                glow.shadowBlurRadius = blur
                glow.shadowOffset = .zero
                glow.shadowColor = Self.neon.withAlphaComponent(alpha)
                glow.set()
                Self.neon.setStroke()
                outline.lineWidth = 1.5
                outline.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.black.setFill()
        outline.fill()
        if hovered {
            (Self.neon.blended(withFraction: 0.55, of: .white) ?? Self.neon).setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        (Self.visualTransform(islandRect: island, scale: scale) as NSAffineTransform).concat()
        let visible = summary.visible
        for slot in 0..<2 {
            let x = island.minX + (slot == 0 ? CGFloat(0) : geometry.leftWing + geometry.gap)
            let wing = slot == 0 ? geometry.leftWing : geometry.rightWing
            let inset = min(Self.horizontalPadding, wing / 2)
            let rect = CGRect(x: x + inset, y: island.minY, width: max(0, wing - inset * 2), height: island.height)
            if slot < visible.count {
                draw(visible[slot], in: rect, slot: slot, overflow: slot == 1 ? summary.overflow : 0)
            } else {
                drawText(slot == 0 ? "amon" : (visible.isEmpty ? "사용량 대기" : ""),
                         in: rect, size: 11, color: .white, alignment: slot == 0 ? .right : .left)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self, window?.isKeyWindow == true {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let visual = Self.visualRect(islandRect: island, scale: scale)
            let ring = Self.shape(in: visual.insetBy(dx: 1, dy: 1))
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
            let blockY = rect.minY + max(0, (rect.height - 32) / 2)
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
    private let screenProvider: () -> UsageIslandScreen?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var enabled = false
    private var sleeping = false
    private var stopped = false
    private var lastScreenFrame: CGRect?
    private var screenWatch: Timer?
    private var pendingScreenCheck: DispatchWorkItem?
    private var screenCheckGeneration = 0
    var isWatchingScreen: Bool { screenWatch?.isValid == true }
    var hasPendingScreenCheck: Bool { pendingScreenCheck != nil && pendingScreenCheck?.isCancelled == false }
    var onGeometryChange: (() -> Void)?
    var anchor: NSView? { !stopped && enabled && panel.isVisible ? view : nil }

    init(onOpen: @escaping (NSView) -> Void, onClose: @escaping () -> Void, makeMenu: @escaping () -> NSMenu,
         isOpen: @escaping () -> Bool = { false }, onSetOpen: ((Bool, NSView) -> Void)? = nil,
         screenProvider: (() -> UsageIslandScreen?)? = nil) {
        self.screenProvider = screenProvider ?? { Self.targetScreen() }
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
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reposition() } })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] note in
                    Task { @MainActor in
                        guard let self, !self.stopped else { return }
                        if note.name == NSWorkspace.accessibilityDisplayOptionsDidChangeNotification {
                            self.view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                            return
                        }
                        if note.name == NSWorkspace.didActivateApplicationNotification,
                           let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                           application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                            return // Opening our native popover must not retarget its own anchor.
                        }
                        if note.name == NSWorkspace.willSleepNotification { self.setSleeping(true); return }
                        if note.name == NSWorkspace.didWakeNotification { self.setSleeping(false); return }
                        self.reposition()
                    }
                })
        }
    }
    private func startMouseMonitors() {
        guard localMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updateMousePassthrough()
                if event.type == .leftMouseDown { self?.scheduleScreenCheck() }
            }
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
        stopScreenWatcher()
        view.resetInteraction()
    }
    private func startScreenWatcher() {
        guard enabled, !sleeping, !stopped, !isWatchingScreen else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.screenWatch === timer else { timer.invalidate(); return }
                self.checkScreen()
            }
        }
        screenWatch = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func stopScreenWatcher() {
        screenWatch?.invalidate(); screenWatch = nil
        cancelPendingScreenCheck()
        lastScreenFrame = nil
    }
    private func cancelPendingScreenCheck() {
        screenCheckGeneration &+= 1
        pendingScreenCheck?.cancel(); pendingScreenCheck = nil
    }
    /// A short delay lets the system update its keyboard-focus display after an
    /// external click. Generation checks invalidate stale disable/re-enable work.
    func scheduleScreenCheck() {
        cancelPendingScreenCheck()
        guard enabled, !sleeping, !stopped else { return }
        let generation = screenCheckGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.screenCheckGeneration == generation else { return }
                self.pendingScreenCheck = nil
                self.checkScreen()
            }
        }
        pendingScreenCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
    /// Cheap focused-display comparison, also used by the 1-second watch timer.
    /// Our popover becoming key must not move the anchor underneath itself.
    func checkScreen() {
        guard enabled, !sleeping, !stopped, !view.isOpen() else { return }
        let screen = screenProvider()
        if screen?.frame != lastScreenFrame { reposition(using: screen) }
    }
    func setSleeping(_ sleeping: Bool) {
        guard !stopped else { return }
        self.sleeping = sleeping
        reposition()
    }
    func update(summary: UsageIslandSummary, enabled: Bool) {
        guard !stopped else { return }
        // 세션 폴링마다 불리므로 내용이 같으면 다시 그리지 않는다.
        let contentChanged = view.summary != summary
        if contentChanged { view.summary = summary }
        if self.enabled != enabled { self.enabled = enabled; reposition() }
        else if contentChanged, enabled { reposition() }
    }
    private func updateMousePassthrough() {
        let inside = containsScreenPoint(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        view.hovered = inside
    }
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        anchor != nil && view.containsScreenPoint(point)
    }
    static func targetScreen() -> UsageIslandScreen? {
        let screens = NSScreen.screens.map {
            UsageIslandScreen(frame: $0.frame, safeTop: $0.safeAreaInsets.top,
                              left: $0.auxiliaryTopLeftArea, right: $0.auxiliaryTopRightArea)
        }
        return UsageIslandScreen.preferred(in: screens, mainFrame: NSScreen.main?.frame)
    }
    private func reposition() {
        guard !stopped else { return }
        reposition(using: enabled && !sleeping ? screenProvider() : nil)
    }
    private func reposition(using screen: UsageIslandScreen?) {
        guard !stopped else { return }
        guard enabled, !sleeping, let screen else {
            if panel.isVisible { onGeometryChange?() }
            panel.orderOut(nil); stopMouseMonitors(); return
        }
        let next = UsageIslandGeometry.make(screen: screen.frame, safeTop: screen.safeTop,
            left: screen.left, right: screen.right, wings: view.fittedWings())
        guard !next.frame.isEmpty else {
            if panel.isVisible { onGeometryChange?() }
            panel.orderOut(nil); stopMouseMonitors(); return
        }
        lastScreenFrame = screen.frame
        let frameChanged = next.frame != view.geometry.frame || next.panelFrame != panel.frame
        if frameChanged { onGeometryChange?(); view.resetInteraction() }
        if next != view.geometry { view.geometry = next }
        if frameChanged {
            panel.setFrame(next.panelFrame, display: true)
            view.frame = CGRect(origin: .zero, size: next.panelFrame.size)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        startMouseMonitors()
        startScreenWatcher()
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
        screenWatch?.invalidate()
        pendingScreenCheck?.cancel()
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
        .init(providerID: "claude", name: "Claude", lines: ["42%"], detail: "Claude Session · 42% 사용",
              accentHex: Palette.hexClaude, lastUsedAt: Date(timeIntervalSince1970: 1_000)),
        .init(providerID: "codex", name: "Codex", lines: ["18%"], detail: "Codex Session · 18% 사용",
              accentHex: Palette.hexCodex, lastUsedAt: Date(timeIntervalSince1970: 2_000)),
        .init(providerID: "grok", name: "Grok", lines: ["5%"], detail: "Grok Session · 5% 사용",
              accentHex: Palette.hexGrok, lastUsedAt: nil)
    ], mode: "사용")

    /// Offscreen production view rendering, with no windows or application services.
    static func render(directory: String) throws {
        _ = NSApplication.shared
        try UsageIslandFonts.validateResources()
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let twoLines = UsageIslandSummary(items: [
            .init(providerID: "claude", name: "Claude", lines: ["58%", "82%"],
                  detail: "Claude · Session 58% 남음 · Week 82% 남음", accentHex: Palette.hexClaude),
            .init(providerID: "openrouter", name: "OpenRouter", lines: ["$4.20"],
                  detail: "OpenRouter · Total usage $4.20 사용", accentHex: Palette.hexOpenRouter)
        ], mode: "남음")
        let wide = UsageIslandSummary(items: [
            .init(providerID: "claude", name: "Claude", lines: ["$123,456,789,012,345.67"],
                  detail: "Synthetic long dollar value · 사용", accentHex: Palette.hexClaude),
            .init(providerID: "codex", name: "Codex", lines: ["123,456,789,012,345,678"],
                  detail: "Synthetic long request count · 사용", accentHex: Palette.hexCodex)
        ], mode: "사용")
        let variants: [(name: String, notched: Bool, summary: UsageIslandSummary, state: String)] = [
            ("island-pill", false, sample, "idle"), ("island-notch", true, sample, "idle"),
            ("island-pill-hover", false, sample, "hover"), ("island-notch-hover", true, sample, "hover"),
            ("island-pill-pressed", false, sample, "pressed"), ("island-notch-pressed", true, sample, "pressed"),
            ("island-notch-two-lines", true, twoLines, "idle"),
            ("island-pill-empty", false, .init(items: [], mode: "사용"), "idle"),
            ("island-notch-wide-pressed", true, wide, "pressed")
        ]
        for variant in variants {
            let notched = variant.notched
            let view = UsageIslandView(frame: .zero)
            view.summary = variant.summary
            let layout = UsageIslandGeometry.make(
                screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: notched ? 38 : 0,
                left: notched ? CGRect(x: 0, y: 944, width: 650, height: 38) : nil,
                right: notched ? CGRect(x: 862, y: 944, width: 650, height: 38) : nil,
                wings: view.fittedWings())
            view.frame = CGRect(origin: .zero, size: layout.panelFrame.size)
            view.geometry = layout
            view.hovered = variant.state != "idle"
            if variant.state == "pressed" { view.setScaleForPreview(UsageIslandView.pressedScale) }
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(layout.panelFrame.width * 2)),
                pixelsHigh: Int(ceil(layout.panelFrame.height * 2)), bitsPerSample: 8, samplesPerPixel: 4,
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
        controller?.onGeometryChange = { popover?.performClose(nil) }
        controller?.update(summary: sample, enabled: true)
        if smoke {
            // Exercise a real NSPanel anchor and transient NSPopover with synthetic
            // mouse input, plus accessibility and disable/stop, without AppState.
            DispatchQueue.main.async {
                let watcherStarted = controller?.isWatchingScreen == true
                let firstClick = click() && popover?.isShown == true
                let secondClick = click() && popover?.isShown == false
                _ = controller?.view.accessibilityPerformPress()
                let opened = popover?.isShown == true
                let originalFrame = controller?.view.geometry.frame
                let refreshed = UsageIslandSummary(items: sample.items.map {
                    UsageIslandItem(providerID: $0.providerID, name: $0.name, lines: $0.lines,
                                    detail: $0.detail + " · refreshed", accentHex: $0.accentHex, lastUsedAt: $0.lastUsedAt)
                }, mode: sample.mode)
                controller?.update(summary: refreshed, enabled: true)
                controller?.scheduleScreenCheck()
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                           object: nil)
                // Allow the 50ms click check, queued app activation, and a complete
                // 1-second screen-watch tick before checking popup stability.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    let stablePopover = popover?.isShown == true && controller?.view.geometry.frame == originalFrame
                        && controller?.isWatchingScreen == true && controller?.hasPendingScreenCheck == false
                    _ = controller?.view.accessibilityPerformPress()
                    let closed = popover?.isShown == false
                    _ = controller?.view.accessibilityPerformPress()
                    let wider = UsageIslandSummary(items: sample.items.map {
                        UsageIslandItem(providerID: $0.providerID, name: $0.name,
                                        lines: $0.lines.map { _ in "$123,456,789,012,345.67" },
                                        detail: $0.detail, accentHex: $0.accentHex, lastUsedAt: $0.lastUsedAt)
                    }, mode: sample.mode)
                    controller?.update(summary: wider, enabled: true)
                    let reflowClosed = popover?.isShown == false && controller?.view.geometry.frame != originalFrame
                    controller?.view.reduceMotion = false // Synthetic view only; never changes the OS setting.
                    let animationStarted = sendMouse(.leftMouseDown) && controller?.view.isAnimatingScale == true
                    controller?.scheduleScreenCheck()
                    controller?.update(summary: wider, enabled: false)
                    let disabled = controller?.anchor == nil && controller?.view.isAnimatingScale == false
                        && controller?.view.scale == 1 && controller?.view.hovered == false
                        && controller?.isWatchingScreen == false && controller?.hasPendingScreenCheck == false
                    controller?.update(summary: wider, enabled: true)
                    let reenabled = controller?.anchor != nil && controller?.isWatchingScreen == true
                    _ = sendMouse(.leftMouseDown)
                    controller?.scheduleScreenCheck()
                    controller?.stop()
                    controller?.update(summary: sample, enabled: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        let stopped = controller?.anchor == nil && controller?.view.isAnimatingScale == false
                            && controller?.view.scale == 1 && controller?.view.hovered == false
                            && controller?.isWatchingScreen == false && controller?.hasPendingScreenCheck == false
                        print("Island native popover smoke: watcherStarted=\(watcherStarted), firstClick=\(firstClick), secondClick=\(secondClick), opened=\(opened), stablePopover=\(stablePopover), closed=\(closed), reflowClosed=\(reflowClosed), animationStarted=\(animationStarted), disabled=\(disabled), reenabled=\(reenabled), stopped=\(stopped)")
                        exit(watcherStarted && firstClick && secondClick && opened && stablePopover && closed && reflowClosed
                             && animationStarted && disabled && reenabled && stopped ? 0 : 1)
                    }
                }
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
        let rect = (anchor as? UsageIslandView)?.popoverAnchorRect ?? anchor.bounds
        preview.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        preview.contentViewController?.view.window?.makeKey()
    }

    private static func click() -> Bool {
        sendMouse(.leftMouseDown) && sendMouse(.leftMouseUp)
    }

    private static func sendMouse(_ type: NSEvent.EventType) -> Bool {
        guard let view = controller?.anchor, let window = view.window else { return false }
        let rect = (view as? UsageIslandView)?.popoverAnchorRect ?? view.bounds
        let point = view.convert(NSPoint(x: rect.minX + 20, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        else { return false }
        window.sendEvent(event)
        return true
    }
}
