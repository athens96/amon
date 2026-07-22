import Foundation
import SwiftUI

/// 이식한 9개 프로바이더 런타임의 등록소.
enum LiveProviderRegistry {
    /// 표시 순서대로 모든 프로바이더 런타임. `hasLocalCredentials()` 로 실제 보유분만 켜진다.
    @MainActor
    static func all() -> [any ProviderRuntime] {
        [
            ClaudeProvider(),
            CodexProvider(),
            CursorProvider(),
            CopilotProvider(),
            AntigravityProvider(),
            DevinProvider(),
            GrokProvider(),
            OpenRouterProvider(),
            ZAIProvider(),
        ]
    }
}

/// 라이브 프로바이더 쿼터의 조회·캐시·주기 갱신을 담당하는 관찰가능 상태.
///
/// openusage 의 `WidgetDataStore` 를 A-mon 규모로 축소한 것 — 각 프로바이더의 최신
/// `ProviderSnapshot` 을 들고 있고, 자격증명이 있는 프로바이더만 갱신한다.
@MainActor
final class LiveProvidersManager: ObservableObject {
    /// providerID → 최신 스냅샷.
    @Published private(set) var snapshots: [String: ProviderSnapshot] = [:]
    /// 로컬 자격증명이 감지된 providerID (표시 대상).
    @Published private(set) var enabledIDs: Set<String> = []
    /// 자격증명 감지가 최소 1회 끝났는지 — 끝나기 전엔 "감지 중" 을 보여준다.
    @Published private(set) var didDetect = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    let runtimes: [any ProviderRuntime]
    private var autoTask: Task<Void, Never>?
    /// 주기 갱신 간격 — openusage 와 동일하게 5분.
    private let interval: TimeInterval = 300

    /// 갱신이 끝날 때마다 활성 프로바이더 스냅샷과 함께 호출된다.
    var onRefreshed: (([ProviderSnapshot]) async -> Void)?

    /// 로컬 로그 기반 스팬드 타일 수집 루틴 — 현재는 빈 결과(라이브 API 데이터만 표시).
    /// 비어있지 않게 되면 프로바이더 카드 라인 뒤에 합류한다.
    private let localSpend = LocalSpendProbe()

    init(runtimes: [any ProviderRuntime]? = nil) {
        self.runtimes = runtimes ?? LiveProviderRegistry.all()
    }

    /// 표시 순서(등록 순서)대로의 런타임.
    var orderedRuntimes: [any ProviderRuntime] { runtimes }

    /// 세션(5시간) percent 미터 중 **사용률이 가장 높은** 값 (0~100 반올림).
    /// 메뉴바 아이콘 옆 "짧은 쿼터 사용 %" 표시용 — 활성 프로바이더의 5h 창
    /// 미터(Claude/Codex Session, Spark, Antigravity 풀, Z.AI 등)를 모두 훑어
    /// 지금 가장 빠듯한 한도의 소진율을 알려준다. 데이터가 없으면 nil.
    var tightestSessionUsedPercent: Int? { tightestSessionUsage?.used }

    /// 세션(5시간) 사용률이 가장 높은 활성 프로바이더와 그 사용률.
    /// 메뉴바 "가장 많이 사용한 도구(자동)" 모드가 어느 도구인지 이름을 붙일 때 쓴다.
    var tightestSessionUsage: (id: String, used: Int)? {
        var worst: (id: String, used: Double)?
        for (id, snapshot) in snapshots where enabledIDs.contains(id) {
            guard let used = Self.maxSessionUsedPercent(in: snapshot) else { continue }
            if worst == nil || used > worst!.used { worst = (id, used) }
        }
        return worst.map { ($0.id, Int($0.used.rounded())) }
    }

    /// 특정 프로바이더의 세션(5시간) 창 미터 중 가장 높은 사용률 (0~100 반올림).
    /// 메뉴바 % 소스를 도구 하나로 고정했을 때 쓴다. 세션 미터가 없으면 nil.
    func sessionUsedPercent(id: String) -> Int? {
        guard enabledIDs.contains(id), let snapshot = snapshots[id] else { return nil }
        return Self.maxSessionUsedPercent(in: snapshot).map { Int($0.rounded()) }
    }

    private static func maxSessionUsedPercent(in snapshot: ProviderSnapshot) -> Double? {
        var worst: Double?
        for line in snapshot.lines {
            guard case .progress(_, let used, _, .percent, _, let periodMs, _) = line,
                  periodMs == MetricPeriod.sessionMs
            else { continue }
            let clamped = max(0, min(100, used))
            if worst == nil || clamped > worst! { worst = clamped }
        }
        return worst
    }

    /// 메뉴바에 보여줄 미터 하나 — 라벨·성격(세션 여부)·포맷·원시 used/limit 를 들고 있어
    /// 뷰가 % 든 금액이든 상황에 맞게 그린다. 퍼센트 미터는 %, 달러/카운트 미터는 그 양을
    /// 메뉴바에 띄운다("% 또는 양").
    struct MenuBarUsage: Equatable {
        let meterLabel: String   // "Session" | "Total usage" | "세션(5시간)" | …
        let isSession: Bool
        let format: ProgressFormat
        let used: Double
        let limit: Double

        /// 색 임계·자동 비교용 0~100 사용률. 퍼센트 미터는 used 자체, 그 외엔 used/limit.
        var usedPercent: Int {
            if case .percent = format { return Int(max(0, min(100, used)).rounded()) }
            guard limit > 0 else { return 0 }
            return Int(max(0, min(100, used / limit * 100)).rounded())
        }

        /// 상한(limit)이 있으면 % 로 표기할 수 있다 — 퍼센트 미터는 항상, 달러·카운트
        /// 미터는 상한이 정해진 경우. 상한 없는 양(무제한 카운트 등)만 원 단위로 남는다.
        private var showsAsPercent: Bool {
            if case .percent = format { return true }
            return limit > 0
        }

        /// 메뉴바에 그릴 짧은 문자열. showingRemaining=true 면 남은 값.
        /// 상한이 정해진 미터는 금액·개수라도 % 로 표기한다(예: Total usage $0.08/$20 → 0%).
        func menuBarText(showingRemaining: Bool) -> String {
            if showsAsPercent {
                let u = Double(usedPercent)
                return "\(Int((showingRemaining ? 100 - u : u).rounded()))%"
            }
            // 상한 없는 양 — 남은 값 개념이 없으므로 사용한 양을 그대로 보여준다.
            switch format {
            case .dollars: return MetricFormat.dollars(max(0, used))
            case .count: return "\(Int(max(0, used).rounded()))"
            case .percent: return "\(usedPercent)%"  // 도달 불가(위에서 처리) — 안전망
            }
        }
    }

    /// 메뉴바에 띄울 미터. `meterLabel` 이 지정되면 그 progress 라인을, 없으면 대표 미터를
    /// 고른다. 세션(5h) 미터가 있으면 그걸(Claude/Codex — 지금 당장 벽에 부딪히는 한도),
    /// 없으면 Total usage → 최고 사용률로 폴백한다. Cursor/Copilot 처럼 세션 창이 없는
    /// 프로바이더도 월간 미터를 띄울 수 있다.
    func menuBarUsage(
        id: String,
        meterLabel: String? = nil,
        fallbackToRepresentative: Bool = true
    ) -> MenuBarUsage? {
        guard enabledIDs.contains(id), let snapshot = snapshots[id] else { return nil }
        if let meterLabel, !meterLabel.isEmpty,
           let picked = Self.meter(in: snapshot, label: meterLabel) {
            return picked  // 사용자가 카드에서 고른 미터. 사라졌으면 아래 대표로 폴백.
        }
        if let meterLabel, !meterLabel.isEmpty, !fallbackToRepresentative {
            return nil
        }
        return Self.representativeMeter(in: snapshot)
    }

    /// 특정 라벨의 progress 미터.
    private static func meter(in snapshot: ProviderSnapshot, label: String) -> MenuBarUsage? {
        for line in snapshot.lines {
            guard case .progress(let l, let used, let limit, let format, _, let periodMs, _) = line,
                  l == label
            else { continue }
            return MenuBarUsage(
                meterLabel: l, isSession: periodMs == MetricPeriod.sessionMs,
                format: format, used: used, limit: limit
            )
        }
        return nil
    }

    /// 대표 미터 — 세션(5h·퍼센트) 중 가장 빠듯한 것 → 없으면 Total usage → 최고 사용률.
    private static func representativeMeter(in snapshot: ProviderSnapshot) -> MenuBarUsage? {
        var session: MenuBarUsage?
        var total: MenuBarUsage?
        var best: MenuBarUsage?
        for line in snapshot.lines {
            guard case .progress(let label, let used, let limit, let format, _, let periodMs, _) = line
            else { continue }
            let u = MenuBarUsage(
                meterLabel: label, isSession: periodMs == MetricPeriod.sessionMs,
                format: format, used: used, limit: limit
            )
            if periodMs == MetricPeriod.sessionMs, case .percent = format {
                if session == nil || u.usedPercent > session!.usedPercent { session = u }
            }
            if label == "Total usage" { total = u }
            if best == nil || u.usedPercent > best!.usedPercent { best = u }
        }
        return session ?? total ?? best
    }

    /// providerID 로 런타임을 찾는다.
    func runtime(id: String) -> (any ProviderRuntime)? {
        runtimes.first { $0.provider.id == id }
    }

    /// 자격증명 감지 후 1회 갱신하고, 이후 주기 타이머를 건다. 앱당 1회만 시작.
    func start() {
        guard autoTask == nil else { return }
        Task { [weak self] in
            await self?.detectEnabled()
            await self?.refreshEnabled()
        }
        autoTask = Task { [weak self] in
            guard let interval = self?.interval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.refreshEnabled()
            }
        }
    }

    /// 어떤 프로바이더가 로컬 자격증명을 갖고 있는지 감지한다(네트워크 X). 순차 실행 —
    /// 여러 keychain 접근이 동시에 프롬프트를 띄우지 않게 한다.
    func detectEnabled() async {
        var enabled: Set<String> = []
        for rt in runtimes where await rt.hasLocalCredentials() {
            enabled.insert(rt.provider.id)
        }
        enabledIDs = enabled
        didDetect = true
    }

    /// 자격증명이 감지된 프로바이더만 순차 갱신한다.
    func refreshEnabled() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        for rt in runtimes where enabledIDs.contains(rt.provider.id) {
            var snapshot = await rt.refresh()
            // 로컬 정보(로그 스캔) 스팬드 라인 수집 루틴 — 지금은 항상 빈 결과라
            // 화면엔 라이브 프로바이더 데이터만 표시된다.
            let spendLines = await localSpend.fetchSpendLines(providerID: rt.provider.id)
            if !spendLines.isEmpty { snapshot.lines.append(contentsOf: spendLines) }
            store(snapshot, for: rt.provider.id)
        }
        lastRefresh = Date()
        isRefreshing = false

        // 활성 프로바이더 스냅샷을 AppState의 로컬 집계/알림 훅으로 넘긴다.
        let active = runtimes
            .filter { enabledIDs.contains($0.provider.id) }
            .compactMap { snapshots[$0.provider.id] }
        await onRefreshed?(active)
    }

    /// 사용자 수동 새로고침 — 자격증명을 재감지하고(새로 로그인한 도구 반영) 갱신한다.
    func manualRefresh() async {
        await detectEnabled()
        await refreshEnabled()
    }

    /// 단일 프로바이더만 갱신 (프로바이더 카드의 개별 새로고침 버튼용).
    func refresh(id: String) async {
        guard let rt = runtime(id: id) else { return }
        let snapshot = await rt.refresh()
        store(snapshot, for: id)
        if snapshot.errorMessage == nil {
            enabledIDs.insert(id)
        }
    }

    /// 갱신 결과 저장 — stale-while-revalidate (openusage 캐싱 규칙 정렬).
    /// 실패(에러 스냅샷)는 마지막 정상 스냅샷을 지우지 않고, 기존 스냅샷 헤더에
    /// 경고(앰버 삼각형)로 표시한다. 다음 성공 갱신이 경고를 자연히 걷어낸다.
    /// 정상 스냅샷이 아직 없으면(첫 조회 실패) 에러 스냅샷을 그대로 노출한다.
    private func store(_ snapshot: ProviderSnapshot, for id: String) {
        if let message = snapshot.errorMessage,
           var existing = snapshots[id], existing.errorMessage == nil {
            existing.warning = "갱신 실패 — 마지막 정상 데이터 표시 중: \(message)"
            snapshots[id] = existing
            return
        }
        snapshots[id] = snapshot
    }
}
