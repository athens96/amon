import AppKit
import Combine
import SwiftUI

/// 실행 진입점.
///
/// 기본은 메뉴바 앱으로 뜨지만, `--scan`/`--login-status` 인자를 주면
/// GUI 없이 동작하고 종료한다 (스크립트/검증용).
@main
enum EntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--scan") {
            HeadlessScan.run()
            return
        }
        if CommandLine.arguments.contains("--providers") {
            HeadlessScan.providers()
            return
        }
        if CommandLine.arguments.contains("--agent-store") {
            HeadlessScan.agentStore()
            return
        }
        if CommandLine.arguments.contains("--agent-upload") {
            HeadlessScan.agentUpload()
            return
        }
        if CommandLine.arguments.contains("--calibrate-test") {
            HeadlessScan.calibrateTest()
            return
        }
        if CommandLine.arguments.contains("--login-status") {
            print("LoginItem: \(LoginItem.statusDescription)")
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--check-update") {
            let url = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
            HeadlessScan.checkUpdate(url)
            return
        }
        AIMonitorApp.main()
    }
}

/// 앱 본체. 실제 UI(상태바 아이템·팝오버·우클릭 메뉴)는 `AppDelegate` 가 구성한다.
/// SwiftUI `App` 은 Scene 이 최소 하나 필요하므로 보이지 않는 `Settings` 를 둔다
/// (accessory 앱이라 메뉴바가 없어 화면엔 나타나지 않음).
struct AIMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// 상태바 아이템 + 팝오버(좌클릭) + 컨텍스트 메뉴(우클릭)를 관리한다.
/// AppKit 콜백은 메인 스레드에서 오므로 @MainActor 로 두어 AppState(@MainActor)
/// 접근을 동기적으로 처리한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI 루트와 반드시 같은 크기여야 한다. 별도 숫자를 두면 호스팅 뷰가
    /// 내용을 강제로 압축해 헤더와 오른쪽 내비게이션이 잘린다.
    private static let popoverSize = MenuBarContentView.preferredSize

    private let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var petOverlay: PetOverlayController?
    private var cancellables = Set<AnyCancellable>()
    private var reservedStatusItemLength: CGFloat = NSStatusItem.variableLength

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock 아이콘·앱 메뉴 없이 순수 메뉴바 앱으로 동작.
        NSApp.setActivationPolicy(.accessory)

        // 좌클릭 시 뜨는 SwiftUI 패널.
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = Self.popoverSize
        let hosting = NSHostingController(
            rootView: MenuBarContentView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .environmentObject(state.liveProviders)
        )
        hosting.view.frame = NSRect(origin: .zero, size: Self.popoverSize)
        popover.contentViewController = hosting

        // 상태바 아이템.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        setStatusIcon()

        petOverlay = PetOverlayController(
            state: state,
            makeContextMenu: { [weak self] in
                self?.makeStatusContextMenu() ?? NSMenu()
            }
        )

        // 아이콘(이름·커스텀 파일) 또는 상태(stage) 변경 시 상태바에 즉시 반영.
        state.settings.$iconIndex
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$useCustomIcon
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$customIconPath
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.$iconStage
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        // 쿼터 갱신(5분 주기)·감지 결과·표시 토글 변경 시 아이콘 옆 잔여 % 갱신.
        state.liveProviders.$snapshots
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.liveProviders.$enabledIDs
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$menuBarQuotaEnabled
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$menuBarQuotaProviderID
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$menuBarQuotaMeterLabel
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$menuBarQuotaSecondMeterLabel
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$menuBarQuotaMeterSlotsByProvider
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$menuBarQuotaShowsRemaining
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        // 라이브 활동(세션/에이전트) 변경 시 상태바 툴팁 갱신.
        state.liveActivity.$sessions
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
        state.settings.$localActivityEnabled
            .sink { [weak self] _ in Task { @MainActor in self?.setStatusIcon() } }
            .store(in: &cancellables)
    }

    typealias MenuBarQuotaEntry = (
        id: String,
        name: String,
        accentHex: String,
        usages: [LiveProvidersManager.MenuBarUsage],
        isAuto: Bool
    )

    /// 메뉴바에 보여줄 provider별 미터 목록. 그래프를 직접 선택한 provider가 있으면
    /// 모두 표시하고, 없으면 기존처럼 고정 provider 대표 미터 또는 자동 tightest provider를 쓴다.
    private func menuBarQuotaEntries() -> [MenuBarQuotaEntry] {
        let lp = state.liveProviders
        let selectedProviders = lp.orderedRuntimes
            .map(\.provider.id)
            .filter { id in
                state.settings.menuBarQuotaMeterSlots(for: id).contains { !$0.isEmpty }
            }
        let providerIDs = selectedProviders.isEmpty
            ? (state.settings.menuBarQuotaProviderID.isEmpty ? [] : [state.settings.menuBarQuotaProviderID])
            : selectedProviders

        var entries: [MenuBarQuotaEntry] = []
        for providerID in providerIDs {
            var usages: [LiveProvidersManager.MenuBarUsage] = []
            let labels = state.settings.menuBarQuotaMeterLabels(for: providerID)
            if labels.isEmpty {
                if let usage = lp.menuBarUsage(id: providerID) { usages.append(usage) }
            } else {
                // 팝업 그래프의 아래쪽 항목이 메뉴바 위쪽에 오도록 실제 그래프 순서를
                // 기준으로 선택된 라벨을 찾은 뒤 역순으로 배치한다.
                let selected = Set(labels)
                let orderedLabels = (lp.snapshots[providerID]?.lines.compactMap { line -> String? in
                    if case .progress(let label, _, _, _, _, _, _) = line,
                       selected.contains(label) { return label }
                    return nil
                } ?? []).reversed()
                var seen = Set<String>()
                for label in orderedLabels where seen.insert(label).inserted {
                    if let usage = lp.menuBarUsage(
                        id: providerID, meterLabel: label, fallbackToRepresentative: false
                    ) {
                        usages.append(usage)
                    }
                }
            }
            guard !usages.isEmpty else { continue }
            let provider = lp.runtime(id: providerID)?.provider
            let name = provider?.displayName ?? providerID
            let accentHex = provider?.accentHex ?? Palette.accentHex
            entries.append((providerID, name, accentHex, Array(usages.prefix(2)), false))
        }
        if !entries.isEmpty { return entries }

        guard let tightest = lp.tightestSessionUsage else { return [] }
        let provider = lp.runtime(id: tightest.id)?.provider
        let name = provider?.displayName ?? tightest.id
        let accentHex = provider?.accentHex ?? Palette.accentHex
        let usage = LiveProvidersManager.MenuBarUsage(
            meterLabel: "세션(5시간)", isSession: true, format: .percent,
            used: Double(tightest.used), limit: 100
        )
        return [(tightest.id, name, accentHex, [usage], true)]
    }

    /// 메뉴바 아이콘으로 그릴 프로바이더 — % 소스와 같은 규칙을 따르되, 고정 도구는
    /// 세션 미터가 없어도(=% 는 생략돼도) 로고는 유지한다. 활성 프로바이더가 하나도
    /// 없으면 nil (내장 아이콘 폴백).
    private func menuBarIconProviderID() -> String? {
        let lp = state.liveProviders
        let selected = state.settings.menuBarQuotaProviderID
        if !selected.isEmpty, lp.enabledIDs.contains(selected) { return selected }
        return lp.tightestSessionUsage?.id
    }

    /// 상태바 아이콘 = 현재 소스 프로바이더의 공식 로고(템플릿).
    /// 프로바이더가 없으면 기존 내장 아이콘(iconIndex×iconStage)·커스텀 파일·SF Symbol
    /// 순으로 폴백. 옆에 세션(5h) 쿼터 잔여 % 를 함께 표시한다(설정 토글).
    private func setStatusIcon() {
        guard let button = statusItem?.button else { return }
        // 프로바이더 공식 로고 우선 — 개별 보기 탭/우클릭 메뉴에서 고른 도구를 따라간다.
        let providerLogo = menuBarIconProviderID().flatMap { providerID -> NSImage? in
            let accentHex = state.liveProviders.runtime(id: providerID)?.provider.accentHex ?? Palette.accentHex
            return ProviderIcons.coloredMenuBarImage(id: providerID, colorHex: accentHex)
        }
        // 커스텀 파일이 켜져 있으면 다음 순위 — 파일이 사라졌으면 내장 아이콘 폴백.
        let custom = state.settings.useCustomIcon
            ? AppIcons.customMenuBarImage(path: state.settings.customIconPath) : nil
        button.image =
            providerLogo
            ?? custom
            ?? AppIcons.menuBarImage(icon: state.settings.iconIndex, stage: state.iconStage)
            ?? NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: "amon"
            )

        // 짧은 쿼터(세션 5h) % — 소스(자동=가장 많이 사용 / 고정 도구)와
        // 표기(사용/남은)는 설정을 따른다. 우클릭 메뉴에서 소스를 고른다.
        var quotaTooltipLine: String?
        if state.settings.menuBarQuotaEnabled {
            let entries = menuBarQuotaEntries()
            let showsRemaining = state.settings.menuBarQuotaShowsRemaining
            if !entries.isEmpty {
                let image = quotaStripImage(entries: entries)
                reserveStatusItemLength(for: image)
                button.image = image
                button.imagePosition = .imageOnly
                button.attributedTitle = NSAttributedString(string: "")
            } else {
                statusItem.length = NSStatusItem.variableLength
                reservedStatusItemLength = NSStatusItem.variableLength
                button.imagePosition = .imageOnly
                button.attributedTitle = NSAttributedString(string: "")
            }
            let mode = showsRemaining ? "남음" : "사용"
            let source = entries.map { entry in
                let prefix = entry.isAuto ? "가장 많이 사용한 도구: \(entry.name)" : entry.name
                let meters = entry.usages.enumerated().map { idx, usage in
                    let text = usage.menuBarText(showingRemaining: showsRemaining)
                    let slot = entry.usages.count > 1 ? (idx == 0 ? "위" : "아래") + " " : ""
                    return "\(slot)\(usage.meterLabel) \(mode) \(text)"
                }.joined(separator: " · ")
                return "\(prefix) — \(meters)"
            }.joined(separator: "\n")
            if !source.isEmpty {
                quotaTooltipLine = "\(source)\n그래프 하단의 상태창 보기 토글로 항목 변경"
            }
        } else {
            statusItem.length = NSStatusItem.variableLength
            reservedStatusItemLength = NSStatusItem.variableLength
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = statusTooltip(quotaLine: quotaTooltipLine)
    }

    private func reserveStatusItemLength(for image: NSImage) {
        let target = ceil(image.size.width + 10)
        if reservedStatusItemLength == NSStatusItem.variableLength || target > reservedStatusItemLength {
            reservedStatusItemLength = target
            statusItem.length = target
        }
    }

    /// 상태바 높이에 맞춰 선택된 provider들을 "아이콘 + 미터 1~2줄" 스트립으로 합성한다.
    private func quotaStripImage(entries: [MenuBarQuotaEntry]) -> NSImage {
        let showsRemaining = state.settings.menuBarQuotaShowsRemaining
        let textAttributes: (LiveProvidersManager.MenuBarUsage, Int) -> [NSAttributedString.Key: Any] = {
            usage, lineCount in
            [
                // 한 줄은 메뉴바 높이에 여유가 있으므로 두 줄(10pt)보다 20% 크게 표시한다.
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: lineCount == 1 ? 12 : 10,
                    weight: .semibold
                ),
                .foregroundColor: usage.usedPercent > 90 ? NSColor.systemRed : NSColor.labelColor,
            ]
        }
        let iconSize: CGFloat = 15
        let gap: CGFloat = 4
        let entryGap: CGFloat = 7
        let height: CGFloat = 22
        let prepared = entries.map { entry in
            let texts = entry.usages.prefix(2).map {
                $0.menuBarText(showingRemaining: showsRemaining)
            }
            let lineCount = texts.count
            let widths = zip(entry.usages, texts).map { usage, text in
                (text as NSString).size(withAttributes: textAttributes(usage, lineCount)).width
            }
            let textWidth = max(widths.max() ?? 0, 12)
            return (entry: entry, texts: texts, width: iconSize + gap + ceil(textWidth))
        }
        let width = prepared.reduce(CGFloat(0)) { $0 + $1.width }
            + entryGap * CGFloat(max(0, prepared.count - 1))
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        var x: CGFloat = 0
        for item in prepared {
            let iconRect = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            if let logo = ProviderIcons.image(id: item.entry.id) {
                NSGraphicsContext.saveGraphicsState()
                logo.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                (Palette.nsColor(fromHex: item.entry.accentHex) ?? .labelColor).setFill()
                iconRect.fill(using: .sourceIn)
                NSGraphicsContext.restoreGraphicsState()
            }

            for (idx, usage) in item.entry.usages.prefix(2).enumerated() {
                let text = item.texts[idx] as NSString
                let lineCount = item.entry.usages.count
                let y: CGFloat = lineCount == 1 ? 4.2 : (idx == 0 ? 10.4 : 0.4)
                text.draw(
                    at: NSPoint(x: x + iconSize + gap, y: y),
                    withAttributes: textAttributes(usage, lineCount)
                )
            }
            x += item.width + entryGap
        }
        return image
    }

    /// 상태바 아이콘 호버 시 뜨는 툴팁 — 쿼터 한 줄 + 라이브 활동 한 줄을 합친다.
    /// 이 기기의 현재 활동 표시가 꺼져 있으면 라이브 줄은 생략한다.
    private func statusTooltip(quotaLine: String?) -> String? {
        var lines: [String] = []
        if let quotaLine { lines.append(quotaLine) }
        if state.settings.localActivityEnabled {
            lines.append(liveActivityTooltipLine())
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// "세션 2개 · 작업 중 1개 · 에이전트 3개 실행 중" 형태의 요약 한 줄.
    private func liveActivityTooltipLine() -> String {
        let sessions = state.liveActivity.sessions
        guard !sessions.isEmpty else { return "라이브 활동 — 실행 중인 세션 없음" }
        let activeCount = sessions.filter { $0.status == "active" }.count
        let agentCount = sessions.reduce(0) { $0 + $1.agents.count }
        var parts = ["세션 \(sessions.count)개"]
        if activeCount > 0 { parts.append("작업 중 \(activeCount)개") }
        if agentCount > 0 { parts.append("에이전트 \(agentCount)개 실행 중") }
        return "라이브 활동 — " + parts.joined(separator: " · ")
    }

    /// 좌클릭 → 패널 토글, 우클릭 → 컨텍스트 메뉴.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from sender: NSStatusBarButton) {
        setPopoverShown(!popover.isShown, from: sender)
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        let menu = makeStatusContextMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    /// 메뉴바와 펫 우클릭이 같은 항목·target·action을 쓰도록 메뉴 생성을 공유한다.
    private func makeStatusContextMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(
            title: "amon \(AppInfo.version)", action: nil, keyEquivalent: ""
        )
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        if let update = state.availableUpdate {
            menu.addItem(
                NSMenuItem(
                    title: "⬇︎ 업데이트 v\(update.version) 설치",
                    action: #selector(installUpdate),
                    keyEquivalent: ""
                )
            )
        }
        menu.addItem(
            NSMenuItem(
                title: "업데이트 확인",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
        )
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "패널 열기", action: #selector(openPanel), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: state.settings.petEnabled ? "펫 잠재우기" : "펫 깨우기",
                action: #selector(togglePet),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    /// 펫을 누르는 순간 열려 있던 상태를 기준으로 표시 여부를 확정한다.
    /// transient popover가 바깥 클릭에 먼저 닫히더라도 다시 열리는 것을 막는다.
    private func setPopoverShown(
        _ shown: Bool,
        from sender: NSStatusBarButton? = nil
    ) {
        if !shown {
            if popover.isShown {
                popover.performClose(nil)
            }
            return
        }
        guard !popover.isShown,
              let anchor = sender ?? statusItem.button
        else { return }
        state.scanOnAppear()  // 열 때 재스캔 (throttle 됨)
        popover.contentSize = Self.popoverSize
        popover.contentViewController?.view.setFrameSize(Self.popoverSize)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // "메뉴바 % 표시" 서브메뉴는 제거됨 — 표시 켜기/끄기는 설정(기본 설정),
    // 소스 선택은 각 그래프 하단의 '상태창 보기' 토글이 담당한다.

    /// 수동 "업데이트 확인" — 자동 체크(10분 주기)와 달리 결과를 알림으로 보여준다.
    @objc private func checkForUpdates() {
        let serverURL = state.settings.serverURL
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showUpdateAlert(
                title: "서버 미설정",
                message: "설정의 '서버 연동 설정'에서 서버 URL을 먼저 입력하세요."
            )
            return
        }
        Task { @MainActor in
            let info = await Updater.checkLatest(serverURL: serverURL)
            self.state.availableUpdate = info
            if let info {
                if self.state.settings.autoUpdateEnabled, !self.state.isInstallingUpdate {
                    self.showUpdateAlert(
                        title: "업데이트 발견",
                        message: "v\(info.version) 설치를 시작합니다. 완료되면 앱이 자동으로 다시 실행됩니다."
                    )
                    self.state.installUpdate()
                } else {
                    self.showUpdateAlert(
                        title: "업데이트 발견",
                        message: "v\(info.version)이 있습니다. 우클릭 메뉴의 '업데이트 설치'로 설치하세요."
                    )
                }
            } else {
                self.showUpdateAlert(
                    title: "최신 버전",
                    message: "현재 amon \(AppInfo.version)이 최신 버전입니다."
                )
            }
        }
    }

    private func showUpdateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openPanel() {
        if let button = statusItem.button, !popover.isShown {
            togglePopover(from: button)
        }
    }

    @objc private func installUpdate() {
        state.installUpdate()
    }

    @objc private func togglePet() {
        if state.settings.petEnabled {
            petOverlay?.tuckAway()
        } else {
            petOverlay?.wake()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
