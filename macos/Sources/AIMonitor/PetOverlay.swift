import AppKit
import Combine
import ImageIO
import SwiftUI

/// amon의 데이터 수집 구조는 그대로 두고, 로컬 활동을 Codex Pet과 같은
/// 상태 체계로 표현하는 비활성 플로팅 패널을 관리한다.
@MainActor
final class PetOverlayController {
    private static let compactSize = NSSize(
        width: PetOverlayGeometry.compactSize.width,
        height: PetOverlayGeometry.compactSize.height
    )
    private static let frameAutosaveName = "AmonPetOverlayFrame"
    /// 완료 후 자동 접기를 판정하는 주기 — 라이브 세션 폴링과 같은 리듬으로 맞춘다.
    private static let visibilityTickInterval: TimeInterval = 5

    private let panel: NSPanel
    private let state: AppState
    private let overlayModel = PetOverlayModel()
    private var cancellables = Set<AnyCancellable>()
    private var showsTaskBubble = false
    /// 펫을 눌러 말풍선을 강제로 여닫은 상태.
    private var bubbleOverride = PetBubbleOverride()
    /// 마지막 자동 판정 — 클릭 즉시 반대로 뒤집을 때 기준으로 쓴다.
    private var lastAutoShowsBubble = false
    /// 히스토리 열기 전 프레임. 닫을 때 펫 위치를 그대로 복원한다.
    private var preHistoryFrame: NSRect?
    /// 리사이즈 드래그를 시작한 시점의 말풍선 크기 — 이동량을 여기에 더한다.
    private var resizeStartBubbleSize: CGSize?
    private var resizeHandle: PetOverlayGeometry.ResizeHandle = .corner

    init(
        state: AppState,
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
                onToggleBubble: { [weak self] in
                    self?.toggleBubble()
                },
                onToggleHistory: { [weak self] in
                    self?.toggleHistory()
                }
            )
        )
        contentView.frame = NSRect(origin: .zero, size: Self.compactSize)
        contentView.shouldToggleBubbleClick = { [weak overlayModel] point, size in
            overlayModel?.isAvatarPoint(point, in: size) ?? false
        }
        contentView.onToggleBubble = { [weak self] in
            self?.toggleBubble()
        }
        contentView.shouldBubbleJumpClick = { [weak self] point, size in
            guard let self, self.showsTaskBubble else { return false }
            return PetOverlayGeometry.bubbleFrame(
                in: size,
                bubblePlacement: self.overlayModel.bubblePlacement
            ).contains(point)
        }
        contentView.onBubbleJump = { [weak self] in
            self?.jumpToSelectedHost()
        }
        contentView.shouldForwardLeftClick = { [weak self] point, size in
            guard let self else { return false }
            let cardHeight = self.state.settings.petBubbleSize.height
            if self.overlayModel.isCarouselControlPoint(
                point,
                in: size,
                cardHeight: cardHeight
            ) {
                return true
            }
            guard self.showsTaskBubble else { return false }
            let placement = self.overlayModel.bubblePlacement
            if self.overlayModel.selectedPresentation?.transcriptPath != nil,
               PetOverlayGeometry.historyControlFrame(
                in: size,
                bubblePlacement: placement,
                cardHeight: cardHeight
            ).contains(point) {
                return true
            }
            if self.overlayModel.showsHistory,
               PetOverlayGeometry.historyAreaFrame(
                   in: size,
                   bubblePlacement: placement,
                   historyHeight: self.overlayModel.historyHeight
               ).contains(point) {
                return true
            }
            return false
        }
        contentView.beginResize = { [weak self] point, size in
            self?.beginResize(at: point, in: size) ?? false
        }
        contentView.onResizeChanged = { [weak self] translation in
            self?.updateResize(translation: translation)
        }
        contentView.resizeCursorZones = { [weak self] size in
            self?.resizeCursorZones(in: size) ?? []
        }
        contentView.onLocomotion = { [weak overlayModel] direction in
            guard overlayModel?.locomotion != direction else { return }
            overlayModel?.locomotion = direction
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

        // 완료 후 자동으로 접으려면 세션 변화가 없어도 시간을 다시 봐야 한다.
        let ticker = Timer
            .publish(every: Self.visibilityTickInterval, on: .main, in: .common)
            .autoconnect()
            .map { _ in () }
            .prepend(())

        Publishers.CombineLatest4(
            state.liveActivity.$sessions,
            state.settings.$petShowsCurrentTask,
            state.settings.$localActivityEnabled,
            state.settings.$petReadyAutoHideSeconds
        )
        .combineLatest(ticker)
        .map { inputs, _ -> (PetPresentation, Bool) in
            let (sessions, showsTask, localActivityEnabled, autoHideSeconds) = inputs
            let presentation = PetStateAdapter.presentation(
                for: sessions,
                localActivityEnabled: true
            )
            return (
                presentation,
                PetBubbleVisibility.showsBubble(
                    presentation: presentation,
                    showsCurrentTask: showsTask,
                    localActivityEnabled: localActivityEnabled,
                    now: Date(),
                    readyAutoHideDelay: autoHideSeconds
                )
            )
        }
        // removeDuplicates 를 걸지 않는다 — 표시 여부가 같아도 상황(상태·대표 세션)이
        // 바뀌면 수동 여닫기를 되돌려야 하는데, 그 변화가 여기서 걸러지면 못 본다.
        .sink { [weak self] presentation, autoShows in
            self?.applyBubbleVisibility(
                context: PetBubbleContext(presentation),
                autoShows: autoShows
            )
        }
        .store(in: &cancellables)

        state.settings.$petEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.setVisible(enabled)
            }
            .store(in: &cancellables)

        overlayModel.$selectedSessionIdentity
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.reloadHistoryIfOpen() }
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
        if !expanded { clearHistoryState() }
        let oldFrame = panel.frame
        let visible = visibleFrame(for: oldFrame)
        let targetFrame: NSRect
        if expanded {
            let fittedBubble = PetOverlayGeometry.bubbleSize(
                state.settings.petBubbleSize,
                fitting: visible
            )
            if fittedBubble != state.settings.petBubbleSize {
                state.settings.petBubbleWidth = fittedBubble.width
                state.settings.petBubbleHeight = fittedBubble.height
            }
            let result = PetOverlayGeometry.expanded(
                from: oldFrame,
                expandedSize: PetOverlayGeometry.panelSize(bubble: fittedBubble),
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
        invalidateResizeCursors()
        setVisible(state.settings.petEnabled)
    }

    // MARK: - 말풍선 표시

    /// 자동 판정에 사용자의 수동 여닫기를 얹어 최종 표시 여부를 정한다.
    private func applyBubbleVisibility(
        context: PetBubbleContext,
        autoShows: Bool
    ) {
        bubbleOverride.sync(context: context)
        lastAutoShowsBubble = autoShows
        let shows = bubbleOverride.resolve(auto: autoShows)
        guard overlayModel.showsBubble != shows || showsTaskBubble != shows else { return }
        overlayModel.showsBubble = shows
        setExpanded(shows)
    }

    /// 펫 좌클릭 — 말풍선을 접었다 폈다 한다.
    ///
    /// 대시보드는 여기서 열지 않는다. 상태바 아이콘이나 우클릭 메뉴가 그 몫이다.
    private func toggleBubble() {
        bubbleOverride.toggle(currentlyShowing: overlayModel.showsBubble)
        applyBubbleVisibility(
            context: bubbleOverride.context
                ?? PetBubbleContext(status: .idle, sessionIdentity: nil),
            autoShows: lastAutoShowsBubble
        )
    }

    /// 말풍선 본문 클릭 시, 확인된 로컬 호스트 앱으로 이동한다.
    private func jumpToSelectedHost() {
        guard let presentation = overlayModel.selectedPresentation else { return }
        let app = PetSessionHost.resolveRunningApp(
            hostApp: presentation.hostApp,
            hostPID: presentation.hostPID
        ) ?? PetSessionHost.redetectRunningApp(
            provider: presentation.provider ?? "",
            cwd: presentation.cwd
        )
        guard let app else { return }
        PetSessionHost.activate(app)
    }

    // MARK: - 히스토리

    private func toggleHistory() {
        if overlayModel.showsHistory {
            closeHistory()
            return
        }
        guard showsTaskBubble,
              overlayModel.selectedPresentation?.transcriptPath != nil
        else { return }
        let frame = panel.frame
        let height = PetOverlayGeometry.historyHeight(
            panelTop: frame.maxY,
            visibleFrame: visibleFrame(for: frame)
        )
        guard height > 0 else { return }
        preHistoryFrame = frame
        overlayModel.showsHistory = true
        overlayModel.historyHeight = height
        panel.setFrame(
            NSRect(
                origin: frame.origin,
                size: NSSize(width: frame.width, height: frame.height + height)
            ),
            display: true,
            animate: false
        )
        invalidateResizeCursors()
        reloadHistoryIfOpen()
    }

    private func closeHistory() {
        guard overlayModel.showsHistory else { return }
        let restore = preHistoryFrame
        clearHistoryState()
        if let restore {
            panel.setFrame(
                PetOverlayGeometry.constrained(restore, to: visibleFrame(for: restore)),
                display: true,
                animate: false
            )
        }
        invalidateResizeCursors()
    }

    private func clearHistoryState() {
        preHistoryFrame = nil
        overlayModel.showsHistory = false
        overlayModel.historyHeight = 0
        overlayModel.historyTurns = []
        overlayModel.historyLoading = false
    }

    private func reloadHistoryIfOpen() {
        guard overlayModel.showsHistory else { return }
        guard let presentation = overlayModel.selectedPresentation else {
            overlayModel.historyTurns = []
            return
        }
        let identity = presentation.sessionIdentity
        let provider = presentation.provider
        let transcriptPath = presentation.transcriptPath
        overlayModel.historyLoading = true
        Task { [weak self] in
            let turns = await Task.detached(priority: .userInitiated) {
                PetSessionHistoryLoader.load(
                    provider: provider,
                    transcriptPath: transcriptPath
                )
            }.value
            guard let self, self.overlayModel.showsHistory else { return }
            guard self.overlayModel.selectedPresentation?.sessionIdentity == identity else {
                self.overlayModel.historyLoading = false
                return
            }
            self.overlayModel.historyTurns = turns
            self.overlayModel.historyLoading = false
        }
    }

    // MARK: - 말풍선 리사이즈

    /// 누른 지점이 말풍선 테두리면 추적을 시작한다.
    private func beginResize(at point: NSPoint, in size: NSSize) -> Bool {
        guard showsTaskBubble, !overlayModel.showsHistory,
              let handle = PetOverlayGeometry.resizeHandle(
                at: point,
                in: size,
                bubblePlacement: overlayModel.bubblePlacement
              )
        else {
            return false
        }
        resizeHandle = handle
        resizeStartBubbleSize = state.settings.petBubbleSize
        return true
    }

    /// 테두리 위에서 커서를 바꿔 크기를 조절할 수 있음을 알린다.
    private func resizeCursorZones(in size: NSSize) -> [(NSRect, NSCursor)] {
        guard showsTaskBubble, !overlayModel.showsHistory,
              PetOverlayGeometry.hasBubble(in: size) else { return [] }
        let placement = overlayModel.bubblePlacement
        let bubble = PetOverlayGeometry.bubbleFrame(in: size, bubblePlacement: placement)
        let thickness = PetOverlayGeometry.resizeEdgeThickness
        let outerEdgeX = placement == .left
            ? bubble.minX
            : bubble.maxX - thickness
        return [
            (
                NSRect(x: outerEdgeX, y: bubble.minY, width: thickness, height: bubble.height),
                .resizeLeftRight
            ),
            (
                NSRect(
                    x: bubble.minX,
                    y: bubble.maxY - thickness,
                    width: bubble.width,
                    height: thickness
                ),
                .resizeUpDown
            ),
        ]
    }

    /// 그립 이동량을 말풍선 크기에 반영한다. 펫이 움직이지 않도록 패널 하단과
    /// 아바타 쪽 모서리는 고정한 채 프레임만 다시 잡는다.
    private func updateResize(translation: CGSize) {
        guard let start = resizeStartBubbleSize else { return }
        let requestedBubble = PetOverlayGeometry.resizedBubbleSize(
            from: start,
            translation: translation,
            bubblePlacement: overlayModel.bubblePlacement,
            handle: resizeHandle
        )
        let frame = panel.frame
        let bubble = PetOverlayGeometry.bubbleSize(
            requestedBubble,
            fitting: visibleFrame(for: frame)
        )
        state.settings.petBubbleWidth = bubble.width
        state.settings.petBubbleHeight = bubble.height
        panel.setFrame(
            PetOverlayGeometry.resizedPanelFrame(
                from: frame,
                bubble: bubble,
                bubblePlacement: overlayModel.bubblePlacement,
                visibleFrame: visibleFrame(for: frame)
            ),
            display: true
        )
        invalidateResizeCursors()
    }

    /// 테두리 위치가 바뀌면 커서 영역도 다시 잡아야 한다.
    private func invalidateResizeCursors() {
        guard let view = panel.contentView else { return }
        panel.invalidateCursorRects(for: view)
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
        let visible = visibleFrame(for: current)
        if overlayModel.showsHistory {
            panel.setFrame(PetOverlayGeometry.constrained(current, to: visible), display: false)
            return
        }
        let constrained: NSRect
        if showsTaskBubble {
            let bubble = PetOverlayGeometry.bubbleSize(
                state.settings.petBubbleSize,
                fitting: visible
            )
            if bubble != state.settings.petBubbleSize {
                state.settings.petBubbleWidth = bubble.width
                state.settings.petBubbleHeight = bubble.height
            }
            constrained = PetOverlayGeometry.resizedPanelFrame(
                from: current,
                bubble: bubble,
                bubblePlacement: overlayModel.bubblePlacement,
                visibleFrame: visible
            )
        } else {
            constrained = PetOverlayGeometry.constrained(current, to: visible)
        }
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
    /// 말풍선 표시 여부는 컨트롤러가 시간까지 보고 정한다 — 뷰는 그 결정을 따른다.
    @Published var showsBubble = false
    /// 사용자가 펫을 끌고 가는 방향 — 놓으면 nil 로 돌아간다.
    @Published var locomotion: PetLocomotion?
    @Published private(set) var presentations: [PetPresentation] = []
    @Published private(set) var selectedSessionIdentity: String?
    @Published var showsHistory = false
    @Published var historyHeight: CGFloat = 0
    @Published var historyTurns: [PetHistoryTurn] = []
    @Published var historyLoading = false

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

    /// 펫 아바타 영역 — 짧은 좌클릭이면 대시보드를 열거나 닫는다.
    func isAvatarPoint(_ point: NSPoint, in size: NSSize) -> Bool {
        PetOverlayGeometry.avatarFrame(
            in: size,
            bubblePlacement: bubblePlacement
        ).contains(point)
    }

    /// SwiftUI 버튼 영역은 hosting view의 일반 이벤트 경로로 보내야
    /// 패널 drag 처리에 가로막히지 않는다.
    func isCarouselControlPoint(_ point: NSPoint, in size: NSSize) -> Bool {
        isCarouselControlPoint(point, in: size, cardHeight: nil)
    }

    func isCarouselControlPoint(
        _ point: NSPoint,
        in size: NSSize,
        cardHeight: CGFloat?
    ) -> Bool {
        guard presentations.count > 1 else { return false }
        return PetOverlayGeometry.carouselControlFrame(
            in: size,
            bubblePlacement: bubblePlacement,
            cardHeight: cardHeight
        ).contains(point)
    }

}

/// 펫 표면의 마우스 처리를 맡는다. 좌클릭 드래그는 패널 이동, 말풍선 테두리는
/// 크기 조절, 캐러셀 버튼만 SwiftUI 로 넘긴다.
private final class PetInteractiveHostingView<Content: View>: NSHostingView<Content> {
    var makeContextMenu: (() -> NSMenu)?
    var shouldToggleBubbleClick: ((NSPoint, NSSize) -> Bool)?
    var onToggleBubble: (() -> Void)?
    var shouldBubbleJumpClick: ((NSPoint, NSSize) -> Bool)?
    var onBubbleJump: (() -> Void)?
    var shouldForwardLeftClick: ((NSPoint, NSSize) -> Bool)?
    var beginResize: ((NSPoint, NSSize) -> Bool)?
    var onResizeChanged: ((CGSize) -> Void)?
    var resizeCursorZones: ((NSSize) -> [(NSRect, NSCursor)])?
    /// 끌고 가는 동안 좌우 방향, 놓으면 nil.
    var onLocomotion: ((PetLocomotion?) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 테두리 위에서 크기 조절 커서를 보여준다. 좌표는 지오메트리(하단 원점)
    /// 기준이라 뷰의 뒤집힌 좌표계로 옮겨 등록한다.
    override func resetCursorRects() {
        super.resetCursorRects()
        for (rect, cursor) in resizeCursorZones?(bounds.size) ?? [] {
            addCursorRect(viewRect(fromGeometry: rect), cursor: cursor)
        }
    }

    private func viewRect(fromGeometry rect: NSRect) -> NSRect {
        guard isFlipped else { return rect }
        return NSRect(
            x: rect.minX,
            y: bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// `NSHostingView` 는 좌표계가 뒤집혀 있어(원점 좌상단) 마우스 y 가 위에서부터
    /// 잰다. 히트 계산은 AppKit 표준(원점 좌하단)인 `PetOverlayGeometry` 기준이므로
    /// 여기서 한 번 되돌린다.
    private func geometryPoint(for event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        guard isFlipped else { return point }
        return NSPoint(x: point.x, y: bounds.height - point.y)
    }

    override func mouseDown(with event: NSEvent) {
        let point = geometryPoint(for: event)
        // 캐러셀 화살표가 테두리와 겹칠 수 있어 버튼을 먼저 살핀다.
        if shouldForwardLeftClick?(point, bounds.size) == true {
            super.mouseDown(with: event)
            return
        }
        if beginResize?(point, bounds.size) == true {
            trackResize()
            return
        }
        let onClick: (() -> Void)?
        if shouldToggleBubbleClick?(point, bounds.size) == true {
            onClick = onToggleBubble
        } else if shouldBubbleJumpClick?(point, bounds.size) == true {
            onClick = onBubbleJump
        } else {
            onClick = nil
        }
        trackDragOrClick(onClick: onClick)
    }

    /// 이동이 먼저다. 임계값을 넘으면 그 순간부터 패널을 끌고, 끝까지 넘지 않은 채
    /// 버튼을 떼면 그때 클릭으로 처리한다. `performDrag` 는 미세한 흔들림에도
    /// 창을 움직여 클릭과 뒤섞이므로 직접 추적한다.
    private func trackDragOrClick(onClick: (() -> Void)?) {
        guard let window else { return }
        let mouseDown = NSEvent.mouseLocation
        let originAtMouseDown = window.frame.origin
        var isDragging = false
        // 주행 방향은 누적 이동량이 아니라 직전 표본과의 차이로 본다 —
        // 오른쪽으로 끌다가 왼쪽으로 되돌리면 그 자리에서 방향이 바뀌어야 한다.
        var lastLocomotionX = mouseDown.x

        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            let dx = current.x - mouseDown.x
            let dy = current.y - mouseDown.y
            if !isDragging, hypot(dx, dy) < PetOverlayGeometry.dragThreshold { continue }
            isDragging = true
            window.setFrameOrigin(
                NSPoint(x: originAtMouseDown.x + dx, y: originAtMouseDown.y + dy)
            )
            let step = current.x - lastLocomotionX
            if abs(step) >= PetOverlayGeometry.locomotionStep {
                lastLocomotionX = current.x
                onLocomotion?(step > 0 ? .right : .left)
            }
        }

        if isDragging {
            onLocomotion?(nil)
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// borderless 패널은 AppKit 기본 리사이즈 테두리가 없으므로 그립 드래그를
    /// 직접 추적한다. 이동량은 화면 좌표(위쪽 +y) 기준으로 넘긴다.
    private func trackResize() {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            onResizeChanged?(
                CGSize(
                    width: current.x - start.x,
                    height: current.y - start.y
                )
            )
        }
    }
}

private struct PetOverlayView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var overlayModel: PetOverlayModel
    let onToggleBubble: () -> Void
    let onToggleHistory: () -> Void

    private var presentation: PetPresentation {
        overlayModel.selectedPresentation ?? .idle
    }

    private var showsBubble: Bool { overlayModel.showsBubble }

    private var bubbleSize: CGSize { settings.petBubbleSize }

    /// 기본 크기보다 얼마나 키웠는지 — 늘어난 높이만큼 입력·출력을 더 보여준다.
    private var extraHeight: CGFloat {
        max(0, bubbleSize.height - PetOverlayGeometry.minimumBubbleSize.height)
    }

    private var detailLineLimit: Int {
        min(6, 1 + Int(extraHeight / 46))
    }

    private var outputLineLimit: Int {
        min(12, 1 + Int(extraHeight / 30))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if showsBubble, overlayModel.bubblePlacement == .left {
                bubbleColumn
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            PetAvatarView(
                status: presentation.status,
                spritePath: settings.petSpritePath,
                spriteRevision: settings.petSpriteRevision,
                spriteVersion: CodexPetSpriteVersion(rawValue: settings.petSpriteVersion) ?? .v1,
                bundled: BundledPet.pet(id: settings.petBundledID),
                locomotion: overlayModel.locomotion
            )
            .frame(
                width: PetOverlayGeometry.avatarSize.width,
                height: PetOverlayGeometry.avatarSize.height
            )
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("말풍선 여닫기")
            .accessibilityAction { onToggleBubble() }

            if showsBubble, overlayModel.bubblePlacement == .right {
                bubbleColumn
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeOut(duration: 0.18), value: showsBubble)
    }

    private var bubbleColumn: some View {
        VStack(alignment: .leading, spacing: Self.historyCardSpacing) {
            if overlayModel.showsHistory {
                historyStack
            }
            activityBubble
        }
    }

    private var activityBubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !settings.localActivityEnabled {
                Label("현재 작업 감지 꺼짐", systemImage: "pause.circle.fill")
                    .font(.amonCaption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("펫 설정에서 현재 작업 감지를 켜면 표시됩니다.")
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                HStack(spacing: 6) {
                    PetStatusIndicator(status: presentation.status)
                    Text(presentation.status.displayName)
                        .font(.amonCaption.weight(.semibold))
                        .foregroundStyle(presentation.status.tint)
                    Spacer(minLength: 4)
                    if let host = presentation.hostApp {
                        Text("⇢ \(host)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help("말풍선을 클릭하면 \(host) 앱으로 이동합니다")
                    }
                    if let provider = presentation.provider {
                        providerBadge(provider)
                    }
                    if overlayModel.presentations.count > 1 {
                        carouselIndicator
                    }
                    if presentation.transcriptPath != nil {
                        historyToggleButton
                    }
                }

                Text(presentation.title)
                    .font(.amonBody.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                summaryLine(
                    label: "입력",
                    systemImage: "arrow.down.left",
                    text: presentation.detail ?? "입력 내용 없음",
                    lineLimit: detailLineLimit
                )
                summaryLine(
                    label: "출력",
                    systemImage: "arrow.up.right",
                    text: presentation.output
                        ?? (presentation.status == .running ? "응답 생성 중…" : "출력 내용 없음"),
                    lineLimit: outputLineLimit
                )

                Spacer(minLength: 0)
                tokenRow
            }
        }
        .padding(12)
        .frame(width: bubbleSize.width, height: bubbleSize.height, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .overlay(
            alignment: overlayModel.bubblePlacement == .left ? .topLeading : .topTrailing
        ) {
            if !overlayModel.showsHistory {
                resizeGrip
            }
        }
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

    private var historyToggleButton: some View {
        Button {
            onToggleHistory()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(
                    overlayModel.showsHistory
                        ? MenuBarContentView.accent
                        : Color.secondary
                )
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(overlayModel.showsHistory ? "히스토리 접기" : "지난 대화 히스토리")
        .accessibilityLabel(
            overlayModel.showsHistory ? "히스토리 접기" : "히스토리 펼치기"
        )
    }

    private var historyStack: some View {
        Group {
            if overlayModel.historyLoading, overlayModel.historyTurns.isEmpty {
                historyPlaceholder("히스토리 읽는 중…", systemImage: "clock.arrow.circlepath")
            } else if overlayModel.historyTurns.isEmpty {
                historyPlaceholder("이 세션에는 보여줄 지난 대화가 없습니다.", systemImage: "tray")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Self.historyCardSpacing) {
                            ForEach(overlayModel.historyTurns) { turn in
                                historyCard(turn)
                                    .id(turn.id)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .onReceive(overlayModel.$historyTurns) { turns in
                        proxy.scrollTo(turns.last?.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(
            width: bubbleSize.width,
            height: max(0, overlayModel.historyHeight - Self.historyCardSpacing),
            alignment: .bottom
        )
    }

    static let historyCardSpacing: CGFloat = 8

    private func historyCard(_ turn: PetHistoryTurn) -> some View {
        let status: PetActivityStatus = turn.reply == nil ? .running : .ready
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                PetStatusIndicator(status: status)
                Text(status.displayName)
                    .font(.amonCaption.weight(.semibold))
                    .foregroundStyle(status.tint)
                Spacer(minLength: 4)
                if let timestamp = turn.timestamp {
                    Text(Self.historyTimeFormatter.string(from: timestamp))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                if let provider = presentation.provider {
                    providerBadge(provider)
                }
            }

            Text(presentation.title)
                .font(.amonBody.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            summaryLine(
                label: "입력",
                systemImage: "arrow.down.left",
                text: turn.prompt,
                lineLimit: 1
            )
            summaryLine(
                label: "출력",
                systemImage: "arrow.up.right",
                text: turn.reply ?? "응답 생성 중…",
                lineLimit: 1
            )

            tokenRow(input: turn.inputTokens, output: turn.outputTokens, total: nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    }

    private func historyPlaceholder(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.amonCaption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            )
    }

    private static let historyTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    /// 말풍선 바깥쪽 위 모서리의 크기 조절 손잡이. 실제 드래그 추적은 AppKit
    /// 호스팅 뷰가 맡고, 여기서는 어디를 끌면 되는지 보여주기만 한다.
    private var resizeGrip: some View {
        Image(
            systemName: overlayModel.bubblePlacement == .left
                ? "arrow.up.left.and.arrow.down.right"
                : "arrow.up.right.and.arrow.down.left"
        )
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.tertiary)
        .frame(
            width: PetOverlayGeometry.resizeGripLength,
            height: PetOverlayGeometry.resizeGripLength
        )
        .contentShape(Rectangle())
        .help("드래그해서 말풍선 크기 조절")
        .accessibilityLabel("말풍선 크기 조절")
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

    /// 한 줄만 보일 때는 라벨을 앞에 붙이고, 말풍선을 키워 여러 줄이 되면
    /// 라벨을 위로 빼서 본문이 넓게 흐르도록 한다.
    @ViewBuilder
    private func summaryLine(
        label: String,
        systemImage: String,
        text: String,
        lineLimit: Int
    ) -> some View {
        if lineLimit <= 1 {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                summaryLabel(label, systemImage: systemImage)
                Text(text)
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                summaryLabel(label, systemImage: systemImage)
                Text(text)
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 어느 도구의 세션인지 — 공식 로고와 이름을 프로바이더 브랜드색으로 함께 보인다.
    /// 로고가 없는 프로바이더는 이름만 같은 색으로 남는다.
    private func providerBadge(_ provider: String) -> some View {
        HStack(spacing: 3) {
            if let icon = ProviderIcons.swiftUIImage(id: provider.lowercased()) {
                icon
                    .resizable()
                    .scaledToFit()
                    .frame(width: 10, height: 10)
            }
            Text(provider.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Palette.providerTint(forID: provider) ?? Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("프로바이더 \(provider)")
    }

    private func summaryLabel(_ label: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text("\(label) ·")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var tokenRow: some View {
        tokenRow(
            input: presentation.inputTokens,
            output: presentation.outputTokens,
            total: presentation.totalTokens
        )
    }

    @ViewBuilder
    private func tokenRow(input: Int?, output: Int?, total: Int?) -> some View {
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
            return "amon 펫, 현재 작업 감지 꺼짐"
        }
        guard presentation.status != .idle else { return "amon 펫, 대기 중" }
        return "amon 펫, \(presentation.status.displayName), \(presentation.title)"
    }
}

private extension PetActivityStatus {
    var displayName: String {
        switch self {
        case .idle: return "대기 중"
        case .running: return "작업 중"
        case .reviewing: return "검토 중"
        case .needsInput: return "입력 필요"
        case .ready: return "완료"
        case .blocked: return "문제 발생"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .running: return MenuBarContentView.accent
        case .reviewing: return .purple
        case .needsInput: return .orange
        case .ready: return .green
        case .blocked: return .red
        }
    }
}

private struct PetAvatarView: View {
    let status: PetActivityStatus
    let spritePath: String
    let spriteRevision: Int
    let spriteVersion: CodexPetSpriteVersion
    let bundled: BundledPet
    let locomotion: PetLocomotion?

    /// 커스텀 펫이 없으면 사용자가 고른 번들 펫으로 떨어진다.
    private var selection: PetSpriteSelection? {
        PetSpriteResolver.selection(
            customPath: spritePath,
            customVersion: spriteVersion,
            bundled: bundled,
            bundledPath: bundled.path
        )
    }

    var body: some View {
        Group {
            if let selection {
                CodexPetSpriteView(
                    path: selection.path,
                    revision: spriteRevision,
                    status: status,
                    spriteVersion: selection.version,
                    locomotion: locomotion
                )
            } else {
                // 번들 리소스까지 없는 예외 상황에서만 직접 그린 펫으로 버틴다.
                AmonFallbackPetView(status: status)
            }
        }
        .shadow(color: status.tint.opacity(0.2), radius: 12, y: 5)
    }
}

/// 공식 호환 시트(v1 1536×1872 · v2 1536×2288 · v3 1536×2496)를 192×208 프레임 프로필로 재생한다.
///
/// 어느 행을 재생할지는 `PetSpriteDirector` 가 정하고, 여기서는 그 결정을
/// 프레임으로 바꿔 그리기만 한다.
private struct CodexPetSpriteView: View {
    let path: String
    let revision: Int
    let status: PetActivityStatus
    let spriteVersion: CodexPetSpriteVersion
    let locomotion: PetLocomotion?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames = PetSpriteFrames.empty
    /// 마우스가 펫의 어느 쪽에 있는지 재려면 아바타의 화면 좌표가 필요하다.
    @State private var hostWindow: NSWindow?
    /// 프레임마다 갱신되는 연출 상태 — 값 타입이면 그리는 도중 @State 를 바꾸게 되므로
    /// 참조로 들고 있는다.
    @State private var director = DirectorBox()

    var body: some View {
        GeometryReader { proxy in
            TimelineView(
                .animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)
            ) { context in
                if let frame = selectedFrame(at: context.date, in: proxy) {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    AmonFallbackPetView(status: status)
                }
            }
        }
        .background(PetWindowAccessor { hostWindow = $0 })
        .task(id: "\(path)|\(revision)|\(spriteVersion.rawValue)") {
            frames = PetSpriteFrames.load(path: path, version: spriteVersion)
        }
    }

    private func selectedFrame(at date: Date, in proxy: GeometryProxy) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        let playback = director.value.playback(
            status: status,
            version: spriteVersion,
            locomotion: locomotion,
            cursor: NSEvent.mouseLocation,
            petCenter: petCenter(in: proxy),
            now: date,
            reduceMotion: reduceMotion
        )
        // 시트에 그 행이 없으면(잘라낸 빈 행 등) 상태 기본 행으로 되돌아간다.
        let animation = frames.frames(for: playback.animation) != nil
            ? playback.animation
            : CodexPetSpriteLayout.animation(for: status)
        guard let strip = frames.frames(for: animation) else { return nil }

        let index: Int?
        if let elapsed = playback.oneShotElapsed, animation == playback.animation {
            index = CodexPetSpriteLayout.oneShotFrameIndex(
                elapsed: elapsed,
                animation: animation,
                frameCount: strip.count,
                reduceMotion: reduceMotion
            )
        } else {
            index = CodexPetSpriteLayout.frameIndex(
                at: date.timeIntervalSinceReferenceDate,
                animation: animation,
                frameCount: strip.count,
                reduceMotion: reduceMotion
            )
        }
        guard let index, strip.indices.contains(index) else { return strip.first }
        return strip[index]
    }

    /// 화면 좌표계의 아바타 중심 — SwiftUI 는 위에서 아래로, 화면은 아래에서
    /// 위로 y 가 늘어나므로 창 상단 기준으로 뒤집는다.
    private func petCenter(in proxy: GeometryProxy) -> CGPoint? {
        guard let window = hostWindow else { return nil }
        let bounds = proxy.frame(in: .global)
        return CGPoint(
            x: window.frame.minX + bounds.midX,
            y: window.frame.maxY - bounds.midY
        )
    }

    @MainActor
    private final class DirectorBox {
        var value = PetSpriteDirector()
    }
}

/// 말풍선 헤더 앞의 상태 표시.
///
/// 작업 중일 때만 점 3개가 차례로 부풀며 지나가고, 나머지 상태는 기존처럼
/// 점 하나로 조용히 둔다. "동작 줄이기"를 켜면 움직이지 않는다.
private struct PetStatusIndicator: View {
    let status: PetActivityStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if status == .running {
            TimelineView(
                .animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)
            ) { context in
                HStack(spacing: 3) {
                    ForEach(0..<PetWorkingDots.dotCount, id: \.self) { index in
                        dot(
                            level: PetWorkingDots.intensity(
                                index: index,
                                time: context.date.timeIntervalSinceReferenceDate,
                                reduceMotion: reduceMotion
                            )
                        )
                    }
                }
            }
            .accessibilityHidden(true)
        } else {
            Circle()
                .fill(status.tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
    }

    private func dot(level: Double) -> some View {
        Circle()
            .fill(status.tint)
            .frame(width: 5, height: 5)
            .scaleEffect(0.72 + 0.46 * level)
            .opacity(0.45 + 0.55 * level)
    }
}

/// SwiftUI 뷰가 올라간 실제 NSWindow 를 잡아 펫 중심의 화면 좌표 기준으로 쓴다.
private struct PetWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
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
