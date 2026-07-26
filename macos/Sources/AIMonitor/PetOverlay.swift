import AppKit
import Combine
import ImageIO
import SwiftUI

/// A-mon의 데이터 수집 구조는 그대로 두고, 로컬 활동을 Codex Pet과 같은
/// 상태 체계로 표현하는 비활성 플로팅 패널을 관리한다.
@MainActor
final class PetOverlayController {
    private static let compactSize = NSSize(width: 148, height: 166)
    private static let expandedSize = NSSize(width: 382, height: 166)
    private static let frameAutosaveName = "AmonPetOverlayFrame"

    private let panel: NSPanel
    private let state: AppState
    private let overlayModel = PetOverlayModel()
    private var cancellables = Set<AnyCancellable>()
    private var showsTaskBubble = false

    init(
        state: AppState,
        isPanelOpen: @escaping () -> Bool,
        onAvatarClick: @escaping (Bool) -> Void,
        makeContextMenu: @escaping () -> NSMenu
    ) {
        self.state = state
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        let contentView = PetInteractiveHostingView(
            rootView: PetOverlayView(
                settings: state.settings,
                overlayModel: overlayModel,
                onAvatarAccessibilityClick: {
                    onAvatarClick(isPanelOpen())
                }
            )
        )
        contentView.frame = NSRect(origin: .zero, size: Self.compactSize)
        contentView.isPanelOpen = isPanelOpen
        contentView.onAvatarClick = onAvatarClick
        contentView.shouldTogglePanelClick = { [weak overlayModel] point, size in
            overlayModel?.isAvatarPoint(point, in: size) ?? false
        }
        contentView.shouldForwardLeftClick = { [weak overlayModel] point, size in
            overlayModel?.isCarouselControlPoint(point, in: size) ?? false
        }
        contentView.makeContextMenu = makeContextMenu
        panel.contentView = contentView

        if panel.setFrameUsingName(Self.frameAutosaveName) {
            let restoredOrigin = panel.frame.origin
            panel.setFrame(
                NSRect(origin: restoredOrigin, size: Self.compactSize),
                display: false
            )
            constrainToVisibleScreen()
        } else {
            placeAtDefaultPosition()
        }

        Publishers.CombineLatest(
            state.liveActivity.$sessions,
            state.settings.$localActivityEnabled
        )
        .map { sessions, enabled in
            PetStateAdapter.presentations(
                for: sessions,
                localActivityEnabled: enabled
            )
        }
        .sink { [weak overlayModel] presentations in
            overlayModel?.update(presentations: presentations)
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(
            state.liveActivity.$sessions,
            state.settings.$petShowsCurrentTask,
            state.settings.$localActivityEnabled
        )
        .map { sessions, showsTask, localActivityEnabled in
            showsTask
                && (
                    !localActivityEnabled
                        || PetStateAdapter.presentation(
                            for: sessions,
                            localActivityEnabled: true
                        ).status != .idle
                )
        }
        .removeDuplicates()
        .sink { [weak self] expanded in
            self?.setExpanded(expanded)
        }
        .store(in: &cancellables)

        state.settings.$petEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.setVisible(enabled)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            self?.constrainToVisibleScreen()
        }
        .store(in: &cancellables)

        // 앱 시작 콜백이 끝난 다음 run loop에서 올려야 accessory 앱의
        // non-activating panel이 다른 앱 뒤에 남지 않는다.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.constrainToVisibleScreen()
            self.setVisible(self.state.settings.petEnabled)
        }
    }

    func wake() {
        state.settings.petEnabled = true
        setVisible(true)
    }

    func tuckAway() {
        state.settings.petEnabled = false
        setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// 좌우 여유를 비교해 말풍선을 화면 안쪽으로 펼치고 펫의 위치를 유지한다.
    private func setExpanded(_ expanded: Bool) {
        guard showsTaskBubble != expanded else {
            setVisible(state.settings.petEnabled)
            return
        }
        showsTaskBubble = expanded
        let oldFrame = panel.frame
        let visible = visibleFrame(for: oldFrame)
        let targetFrame: NSRect
        if expanded {
            let result = PetOverlayGeometry.expanded(
                from: oldFrame,
                expandedSize: Self.expandedSize,
                visibleFrame: visible
            )
            overlayModel.bubblePlacement = result.bubblePlacement
            targetFrame = result.frame
        } else {
            targetFrame = PetOverlayGeometry.collapsed(
                from: oldFrame,
                compactSize: Self.compactSize,
                bubblePlacement: overlayModel.bubblePlacement,
                visibleFrame: visible
            )
        }
        panel.setFrame(targetFrame, display: true, animate: true)
        constrainToVisibleScreen()
        setVisible(state.settings.petEnabled)
    }

    private func placeAtDefaultPosition() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(
            x: 0, y: 0, width: 1440, height: 900
        )
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: screenFrame.maxX - size.width - 24,
                y: screenFrame.minY + 24
            )
        )
    }

    /// 해상도·배율·모니터 구성이 바뀌어 저장 좌표가 화면 밖으로 나간 경우
    /// 펫 전체가 보이도록 가장 가까운 가시 영역 안으로 되돌린다.
    private func constrainToVisibleScreen() {
        let current = panel.frame
        let constrained = PetOverlayGeometry.constrained(
            current,
            to: visibleFrame(for: current)
        )
        panel.setFrame(constrained, display: false)
    }

    private func visibleFrame(for frame: NSRect) -> NSRect {
        NSScreen.screens.first { $0.visibleFrame.intersects(frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

@MainActor
private final class PetOverlayModel: ObservableObject {
    @Published var bubblePlacement: PetBubblePlacement = .left
    @Published private(set) var presentations: [PetPresentation] = []
    @Published private(set) var selectedSessionIdentity: String?

    var selectedIndex: Int {
        PetCarousel.index(
            selectedIdentity: selectedSessionIdentity,
            in: presentations
        )
    }

    var selectedPresentation: PetPresentation? {
        guard presentations.indices.contains(selectedIndex) else { return nil }
        return presentations[selectedIndex]
    }

    func update(presentations newPresentations: [PetPresentation]) {
        let previousIndex = selectedIndex
        let selection = PetCarousel.preservedIdentity(
            selectedIdentity: selectedSessionIdentity,
            previousIndex: previousIndex,
            in: newPresentations
        )
        presentations = newPresentations
        selectedSessionIdentity = selection
    }

    func select(offset: Int) {
        selectedSessionIdentity = PetCarousel.movedIdentity(
            selectedIdentity: selectedSessionIdentity,
            offset: offset,
            in: presentations
        )
    }

    /// SwiftUI 버튼 영역은 hosting view의 일반 이벤트 경로로 보내야
    /// 패널 drag 처리에 가로막히지 않는다.
    func isCarouselControlPoint(_ point: NSPoint, in size: NSSize) -> Bool {
        guard presentations.count > 1 else { return false }
        return PetOverlayGeometry.carouselControlFrame(
            in: size,
            bubblePlacement: bubblePlacement
        ).contains(point)
    }

    func isAvatarPoint(_ point: NSPoint, in size: NSSize) -> Bool {
        PetOverlayGeometry.avatarFrame(
            in: size,
            bubblePlacement: bubblePlacement
        ).contains(point)
    }
}

/// 클릭과 드래그를 분리한다. NSPanel의 background dragging을 켜면 SwiftUI
/// onTapGesture가 사라질 수 있어, AppKit의 단일 mouseDown 흐름에서 이동량을 본다.
private final class PetInteractiveHostingView<Content: View>: NSHostingView<Content> {
    var isPanelOpen: (() -> Bool)?
    var onAvatarClick: ((Bool) -> Void)?
    var makeContextMenu: (() -> NSMenu)?
    var shouldTogglePanelClick: ((NSPoint, NSSize) -> Bool)?
    var shouldForwardLeftClick: ((NSPoint, NSSize) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if shouldForwardLeftClick?(point, bounds.size) == true {
            super.mouseDown(with: event)
            return
        }
        let wasPanelOpen = isPanelOpen?() ?? false
        let start = NSEvent.mouseLocation
        window?.performDrag(with: event)
        let end = NSEvent.mouseLocation
        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance < 4,
           shouldTogglePanelClick?(point, bounds.size) == true {
            onAvatarClick?(wasPanelOpen)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private struct PetOverlayView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var overlayModel: PetOverlayModel
    let onAvatarAccessibilityClick: () -> Void

    private var presentation: PetPresentation {
        overlayModel.selectedPresentation ?? .idle
    }

    private var showsBubble: Bool {
        settings.petShowsCurrentTask
            && (!settings.localActivityEnabled || presentation.status != .idle)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if showsBubble, overlayModel.bubblePlacement == .left {
                activityBubble
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            PetAvatarView(
                status: presentation.status,
                spritePath: settings.petSpritePath
            )
            .frame(width: 126, height: 148)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onAvatarAccessibilityClick()
            }

            if showsBubble, overlayModel.bubblePlacement == .right {
                activityBubble
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeOut(duration: 0.18), value: showsBubble)
    }

    private var activityBubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !settings.localActivityEnabled {
                Label("작업 감지 꺼짐", systemImage: "pause.circle.fill")
                    .font(.amonCaption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("펫 설정 또는 우클릭 메뉴에서 현재 작업 감지를 켜세요.")
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(presentation.status.tint)
                        .frame(width: 7, height: 7)
                    Text(presentation.status.displayName)
                        .font(.amonCaption.weight(.semibold))
                        .foregroundStyle(presentation.status.tint)
                    Spacer(minLength: 4)
                    if let provider = presentation.provider {
                        Text(provider.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    if overlayModel.presentations.count > 1 {
                        carouselIndicator
                    }
                }

                Text(presentation.title)
                    .font(.amonBody.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                summaryLine(
                    label: "입력",
                    systemImage: "arrow.down.left",
                    text: presentation.detail ?? "입력 내용 없음"
                )
                summaryLine(
                    label: "출력",
                    systemImage: "arrow.up.right",
                    text: presentation.output
                        ?? (presentation.status == .running ? "응답 생성 중…" : "출력 내용 없음")
                )

                tokenRow
            }
        }
        .padding(12)
        .frame(width: 226, height: 150, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .accessibilityAdjustableAction { direction in
            guard overlayModel.presentations.count > 1 else { return }
            switch direction {
            case .increment:
                overlayModel.select(offset: 1)
            case .decrement:
                overlayModel.select(offset: -1)
            @unknown default:
                break
            }
        }
    }

    private var carouselIndicator: some View {
        HStack(spacing: 4) {
            Button {
                overlayModel.select(offset: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("이전 동시 세션")

            Text(
                "\(overlayModel.selectedIndex + 1)/\(overlayModel.presentations.count)"
            )
                .monospacedDigit()

            Button {
                overlayModel.select(offset: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("다음 동시 세션")
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(MenuBarContentView.accent)
        .frame(width: 68, height: 22)
        .contentShape(Rectangle())
        .accessibilityLabel(
            "동시 세션 \(overlayModel.selectedIndex + 1)/\(overlayModel.presentations.count)"
        )
    }

    private func summaryLine(
        label: String,
        systemImage: String,
        text: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text("\(label) ·")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.amonCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var tokenRow: some View {
        let input = presentation.inputTokens
        let output = presentation.outputTokens
        let total = presentation.totalTokens
        HStack(spacing: 8) {
            if let input {
                Label("입력 \(TokenFormat.compact(input))", systemImage: "arrow.down.left")
                    .help("현재 세션 입력 토큰 \(input.formatted())")
            }
            if let output {
                Label("출력 \(TokenFormat.compact(output))", systemImage: "arrow.up.right")
                    .help("현재 세션 출력 토큰 \(output.formatted())")
            }
            if input == nil, output == nil, let total {
                Label("합계 \(TokenFormat.compact(total))", systemImage: "sum")
                    .help("현재 세션 총 토큰 \(total.formatted())")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.tertiary)
    }

    private var accessibilityDescription: String {
        guard settings.localActivityEnabled else {
            return "A-mon 펫, 현재 작업 감지 꺼짐"
        }
        guard presentation.status != .idle else { return "A-mon 펫, 대기 중" }
        return "A-mon 펫, \(presentation.status.displayName), \(presentation.title)"
    }
}

private extension PetActivityStatus {
    var displayName: String {
        switch self {
        case .idle: return "대기 중"
        case .running: return "작업 중"
        case .needsInput: return "입력 필요"
        case .ready: return "완료"
        case .blocked: return "문제 발생"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .running: return MenuBarContentView.accent
        case .needsInput: return .orange
        case .ready: return .green
        case .blocked: return .red
        }
    }
}

private struct PetAvatarView: View {
    let status: PetActivityStatus
    let spritePath: String

    var body: some View {
        Group {
            if !spritePath.isEmpty, FileManager.default.fileExists(atPath: spritePath) {
                CodexPetSpriteView(path: spritePath, status: status)
            } else {
                AmonFallbackPetView(status: status)
            }
        }
        .shadow(color: status.tint.opacity(0.2), radius: 12, y: 5)
    }
}

/// 공식 V1/V2 호환 시트의 표준 192×208 프레임 행을 재생한다.
private struct CodexPetSpriteView: View {
    let path: String
    let status: PetActivityStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [CGImage] = []

    private var animation: CodexPetSpriteLayout.Animation {
        CodexPetSpriteLayout.animation(for: status)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { context in
            if let frame = selectedFrame(at: context.date) {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                AmonFallbackPetView(status: status)
            }
        }
        .task(id: "\(path)|\(animation.rawValue)") {
            frames = Self.loadFrames(path: path, animation: animation)
        }
    }

    private func selectedFrame(at date: Date) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        guard let index = CodexPetSpriteLayout.frameIndex(
            at: date.timeIntervalSinceReferenceDate,
            animation: animation,
            reduceMotion: reduceMotion
        ), frames.indices.contains(index)
        else {
            return frames.first
        }
        return frames[index]
    }

    private static func loadFrames(
        path: String,
        animation: CodexPetSpriteLayout.Animation
    ) -> [CGImage] {
        guard let strip = CodexPetSpriteLayout.strips[animation],
              let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, nil
              ),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return []
        }

        return (0..<strip.frameCount).compactMap { column in
            guard let rect = CodexPetSpriteLayout.frameRect(
                column: column,
                animation: animation
            ) else { return nil }
            return sheet.cropping(to: rect)
        }
    }
}

private struct AmonFallbackPetView: View {
    let status: PetActivityStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)
        ) { context in
            let motion = AmonPetMotion.sample(
                status: status,
                time: context.date.timeIntervalSinceReferenceDate,
                reduceMotion: reduceMotion
            )
            petBody(motion: motion)
        }
    }

    private func petBody(motion: AmonPetMotionSample) -> some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            status.tint.opacity(0.92),
                            MenuBarContentView.accent.opacity(0.72),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 70, height: 72)
                .offset(y: 31)

            ear(x: -35)
            ear(x: 35)

            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 94, height: 88)
                .overlay(face)
                .overlay(
                    Circle()
                        .strokeBorder(status.tint.opacity(0.55), lineWidth: 3)
                )

            if status == .ready {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.yellow)
                    .offset(x: 49, y: -44)
                    .scaleEffect(motion.sparkleScale)
            }

            statusDot(scale: motion.statusDotScale)
                .offset(x: 42, y: 38)
        }
        .offset(x: motion.offsetX, y: motion.offsetY)
        .rotationEffect(.degrees(motion.rotationDegrees))
        .scaleEffect(motion.scale)
        .animation(
            .linear(duration: 1.0 / 24.0),
            value: motion
        )
    }

    private func ear(x: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(status.tint.opacity(0.84))
            .frame(width: 34, height: 40)
            .rotationEffect(.degrees(x < 0 ? -27 : 27))
            .offset(x: x, y: -37)
    }

    private var face: some View {
        VStack(spacing: 12) {
            HStack(spacing: 25) {
                Circle().fill(Color.primary).frame(width: 10, height: 12)
                Circle().fill(Color.primary).frame(width: 10, height: 12)
            }
            Capsule()
                .trim(from: 0, to: status == .blocked ? 0.45 : 1)
                .stroke(
                    status == .blocked ? Color.red : Color.primary,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 24, height: 10)
                .rotationEffect(.degrees(status == .blocked ? 180 : 0))
        }
        .offset(y: 5)
    }

    private func statusDot(scale: Double) -> some View {
        Circle()
            .fill(status.tint)
            .frame(width: 18, height: 18)
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
            )
            .scaleEffect(scale)
    }
}
