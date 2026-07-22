import SwiftUI

/// 사용자 설정 — 3개 도구의 로그 폴더 경로를 저장한다.
///
/// `UserDefaults` 에 영속하며, 값이 없으면 각 도구의 `defaultPath` 를 쓴다.
/// 설정 화면의 TextField 는 `binding(for:)` 으로 직접 바인딩한다.
@MainActor
final class AppSettings: ObservableObject {
    @Published var claudePath: String { didSet { persist(.claudeCode, claudePath) } }
    @Published var codexPath: String { didSet { persist(.codex, codexPath) } }
    @Published var openCodePath: String { didSet { persist(.openCode, openCodePath) } }
    @Published var cursorPath: String { didSet { persist(.cursor, cursorPath) } }
    @Published var geminiPath: String { didSet { persist(.gemini, geminiPath) } }
    @Published var qwenPath: String { didSet { persist(.qwen, qwenPath) } }
    @Published var copilotPath: String { didSet { persist(.copilot, copilotPath) } }

    /// 앱 업데이트 서버 베이스 URL. 예: https://monitor.example.com
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "server.url") } }

    /// 메뉴바 아이콘 선택 (0 ~ AppIcons.count-1).
    @Published var iconIndex: Int { didSet { defaults.set(iconIndex, forKey: "icon.index") } }

    /// 커스텀 메뉴바 아이콘 사용 여부 — 켜면 내장 5종 대신 customIconPath 이미지를 쓴다.
    @Published var useCustomIcon: Bool {
        didSet { defaults.set(useCustomIcon, forKey: "icon.useCustom") }
    }

    /// 커스텀 메뉴바 아이콘 파일 경로 — 선택 시 앱 지원 폴더로 복사한 사본 경로.
    /// 파일이 사라지면 렌더 시점에 내장 아이콘으로 폴백한다.
    @Published var customIconPath: String {
        didSet { defaults.set(customIconPath, forKey: "icon.customPath") }
    }

    /// 쿼터 한도 임박(잔여 10% 미만) macOS 알림 켜기/끄기. 기본 켬.
    @Published var quotaAlertsEnabled: Bool {
        didSet { defaults.set(quotaAlertsEnabled, forKey: "quota.alerts") }
    }

    /// 새 버전 발견 시 자동 설치 — 주기 체크(10분)가 상위 버전을 찾으면 클릭 없이
    /// 다운로드→검증→교체→재시작한다. 끄면 메뉴에 설치 항목만 노출. 기본 켬.
    @Published var autoUpdateEnabled: Bool {
        didSet { defaults.set(autoUpdateEnabled, forKey: "update.auto") }
    }

    /// 메뉴바 아이콘 옆 세션(5시간) 쿼터 잔여 % 표시. 기본 켬.
    @Published var menuBarQuotaEnabled: Bool {
        didSet { defaults.set(menuBarQuotaEnabled, forKey: "menubar.quota") }
    }

    /// 메뉴바 % 의 소스 — ""(기본) = 가장 많이 사용한 도구 자동 선택,
    /// 그 외엔 고정할 providerID. 우클릭 메뉴 또는 프로바이더 카드에서 선택한다.
    @Published var menuBarQuotaProviderID: String {
        didSet { defaults.set(menuBarQuotaProviderID, forKey: "menubar.quotaProvider") }
    }

    /// 고정 프로바이더 안에서 메뉴바에 띄울 특정 미터(그래프) 라벨 — ""(기본)이면 대표
    /// 미터(세션→Total usage→최고 사용률)로 자동 선택. 카드의 미터를 클릭하면 그 라벨로
    /// 고정된다. 지정 라벨이 스냅샷에서 사라지면 대표 미터로 폴백한다.
    @Published var menuBarQuotaMeterLabel: String {
        didSet { defaults.set(menuBarQuotaMeterLabel, forKey: "menubar.quotaMeter") }
    }

    /// 같은 프로바이더에서 메뉴바 두 번째 줄에 띄울 미터 라벨. 비어 있으면 한 줄만 표시한다.
    @Published var menuBarQuotaSecondMeterLabel: String {
        didSet { defaults.set(menuBarQuotaSecondMeterLabel, forKey: "menubar.quotaMeter.second") }
    }

    /// providerID 별 메뉴바 미터 슬롯. 값은 항상 `[위, 아래]` 2칸이며 빈 문자열은 빈 슬롯.
    /// 기존 `menuBarQuotaMeterLabel`/`menuBarQuotaSecondMeterLabel` 는 구버전 설정 호환용으로 유지한다.
    @Published var menuBarQuotaMeterSlotsByProvider: [String: [String]] {
        didSet { defaults.set(menuBarQuotaMeterSlotsByProvider, forKey: "menubar.quotaMetersByProvider") }
    }

    /// 메뉴바 % 표기 방식 — false(기본) = 사용한 %, true = 남은 %.
    @Published var menuBarQuotaShowsRemaining: Bool {
        didSet { defaults.set(menuBarQuotaShowsRemaining, forKey: "menubar.quotaRemaining") }
    }

    /// 대시보드 보기 모드 — "all"(전체 보기: 통합 리스트) | "each"(개별 보기: 프로바이더 탭).
    @Published var dashboardMode: String {
        didSet { defaults.set(dashboardMode, forKey: "ui.dashboardMode") }
    }

    /// 개별 보기에서 마지막 선택한 탭 (providerID 또는 "local:<tool rawValue>").
    @Published var selectedProviderTab: String {
        didSet { defaults.set(selectedProviderTab, forKey: "ui.selectedTab") }
    }

    /// 최근 7일간 사용 흔적이 없는 계정(프로바이더/로컬 도구) 숨기기. 기본 켬.
    @Published var hideInactiveAccounts: Bool {
        didSet { defaults.set(hideInactiveAccounts, forKey: "ui.hideInactive") }
    }

    /// Claude Code 라이브 세션·서브에이전트 로컬 표시. 켜면 Claude Code 훅이 설치된다.
    @Published var liveActivityEnabled: Bool {
        didSet { defaults.set(liveActivityEnabled, forKey: "live.enabled") }
    }

    private let defaults = UserDefaults.standard

    init() {
        // 초기화 시엔 didSet 이 호출되지 않으므로 저장 부작용 없이 로드된다.
        func load(_ tool: AITool) -> String {
            UserDefaults.standard.string(forKey: Self.key(tool)) ?? tool.defaultPath
        }
        claudePath = load(.claudeCode)
        codexPath = load(.codex)
        openCodePath = load(.openCode)
        cursorPath = load(.cursor)
        geminiPath = load(.gemini)
        qwenPath = load(.qwen)
        copilotPath = load(.copilot)
        serverURL = UserDefaults.standard.string(forKey: "server.url") ?? ""
        let idx = UserDefaults.standard.object(forKey: "icon.index") as? Int ?? 0
        iconIndex = min(max(idx, 0), AppIcons.iconCount - 1)
        useCustomIcon = UserDefaults.standard.object(forKey: "icon.useCustom") as? Bool ?? false
        customIconPath = UserDefaults.standard.string(forKey: "icon.customPath") ?? ""
        quotaAlertsEnabled = UserDefaults.standard.object(forKey: "quota.alerts") as? Bool ?? true
        autoUpdateEnabled = UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true
        menuBarQuotaEnabled = UserDefaults.standard.object(forKey: "menubar.quota") as? Bool ?? true
        let loadedQuotaProviderID =
            UserDefaults.standard.string(forKey: "menubar.quotaProvider") ?? ""
        let loadedPrimaryMeter =
            UserDefaults.standard.string(forKey: "menubar.quotaMeter") ?? ""
        let loadedSecondMeter =
            UserDefaults.standard.string(forKey: "menubar.quotaMeter.second") ?? ""
        menuBarQuotaProviderID = loadedQuotaProviderID
        menuBarQuotaMeterLabel = loadedPrimaryMeter
        menuBarQuotaSecondMeterLabel = loadedSecondMeter
        var loadedMeterSlots = Self.loadMeterSlots(from: UserDefaults.standard)
        if !loadedQuotaProviderID.isEmpty, loadedMeterSlots[loadedQuotaProviderID] == nil {
            let migrated = Self.normalizedMeterSlots([loadedPrimaryMeter, loadedSecondMeter])
            if migrated.contains(where: { !$0.isEmpty }) {
                loadedMeterSlots[loadedQuotaProviderID] = migrated
            }
        }
        menuBarQuotaMeterSlotsByProvider = loadedMeterSlots
        menuBarQuotaShowsRemaining =
            UserDefaults.standard.object(forKey: "menubar.quotaRemaining") as? Bool ?? false
        dashboardMode = UserDefaults.standard.string(forKey: "ui.dashboardMode") ?? "all"
        selectedProviderTab = UserDefaults.standard.string(forKey: "ui.selectedTab") ?? ""
        hideInactiveAccounts = UserDefaults.standard.object(forKey: "ui.hideInactive") as? Bool ?? true
        liveActivityEnabled = UserDefaults.standard.object(forKey: "live.enabled") as? Bool ?? false
    }

    private static func key(_ tool: AITool) -> String { "path.\(tool.rawValue)" }

    private static func loadMeterSlots(from defaults: UserDefaults) -> [String: [String]] {
        let raw = defaults.dictionary(forKey: "menubar.quotaMetersByProvider") ?? [:]
        var out: [String: [String]] = [:]
        for (providerID, value) in raw {
            guard let labels = value as? [String] else { continue }
            let slots = normalizedMeterSlots(labels)
            if slots.contains(where: { !$0.isEmpty }) {
                out[providerID] = slots
            }
        }
        return out
    }

    private static func normalizedMeterSlots(_ labels: [String]) -> [String] {
        var out = Array(labels.prefix(2)).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while out.count < 2 { out.append("") }
        if out[0] == out[1] { out[1] = "" }
        return out
    }

    func menuBarQuotaMeterSlots(for providerID: String) -> [String] {
        if let slots = menuBarQuotaMeterSlotsByProvider[providerID] {
            return Self.normalizedMeterSlots(slots)
        }
        return ["", ""]
    }

    func menuBarQuotaMeterLabels(for providerID: String) -> [String] {
        menuBarQuotaMeterSlots(for: providerID).filter { !$0.isEmpty }
    }

    func setMenuBarQuotaMeterSlots(_ slots: [String], for providerID: String) {
        let normalized = Self.normalizedMeterSlots(slots)
        var next = menuBarQuotaMeterSlotsByProvider
        if normalized.allSatisfy(\.isEmpty) {
            next.removeValue(forKey: providerID)
        } else {
            next[providerID] = normalized
        }
        menuBarQuotaMeterSlotsByProvider = next
        if providerID == menuBarQuotaProviderID {
            menuBarQuotaMeterLabel = normalized[0]
            menuBarQuotaSecondMeterLabel = normalized[1]
        }
    }

    private func persist(_ tool: AITool, _ value: String) {
        defaults.set(value, forKey: Self.key(tool))
    }

    /// 도구의 현재 경로.
    func path(for tool: AITool) -> String {
        switch tool {
        case .claudeCode: return claudePath
        case .codex: return codexPath
        case .openCode: return openCodePath
        case .cursor: return cursorPath
        case .gemini: return geminiPath
        case .qwen: return qwenPath
        case .copilot: return copilotPath
        }
    }

    /// TextField 바인딩.
    func binding(for tool: AITool) -> Binding<String> {
        switch tool {
        case .claudeCode:
            return Binding(get: { self.claudePath }, set: { self.claudePath = $0 })
        case .codex:
            return Binding(get: { self.codexPath }, set: { self.codexPath = $0 })
        case .openCode:
            return Binding(get: { self.openCodePath }, set: { self.openCodePath = $0 })
        case .cursor:
            return Binding(get: { self.cursorPath }, set: { self.cursorPath = $0 })
        case .gemini:
            return Binding(get: { self.geminiPath }, set: { self.geminiPath = $0 })
        case .qwen:
            return Binding(get: { self.qwenPath }, set: { self.qwenPath = $0 })
        case .copilot:
            return Binding(get: { self.copilotPath }, set: { self.copilotPath = $0 })
        }
    }

    /// 기본 경로로 되돌린다.
    func reset(_ tool: AITool) {
        switch tool {
        case .claudeCode: claudePath = tool.defaultPath
        case .codex: codexPath = tool.defaultPath
        case .openCode: openCodePath = tool.defaultPath
        case .cursor: cursorPath = tool.defaultPath
        case .gemini: geminiPath = tool.defaultPath
        case .qwen: qwenPath = tool.defaultPath
        case .copilot: copilotPath = tool.defaultPath
        }
    }
}
