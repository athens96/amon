import AppKit
import SwiftUI

/// 통합 대시보드 — 로컬 토큰 사용량(UsageScanner)과 프로바이더 라이브 쿼터를
/// openusage 방식의 프로바이더 카드 하나로 합쳐 보여준다.
///
/// 보기 모드 2종(세그먼트로 전환, 선택 영속):
/// - **전체 보기**: 히어로(오늘 총합) + 모든 프로바이더/로컬 카드 세로 나열.
/// - **개별 보기**: 원본 openusage 처럼 프로바이더별 탭 스트립 — 선택한 탭의
///   쿼터 라인 + 확장 로컬 상세(오늘/누적 브레이크다운·모델 전체·최근 7일·비용).
///
/// 카드 = 쿼터 미터(페이스 색·리셋 카운트다운·투영) + %→토큰 추정(캘리브레이션)
///       + 로컬 로그 소비(오늘/누적) + 퀵링크.
/// 프로바이더가 감지되지 않았지만 로컬 사용 기록이 있는 도구(OpenCode 등)는
/// 로컬 전용 카드/탭으로 표시된다.
struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var providers: LiveProvidersManager
    @EnvironmentObject private var settings: AppSettings

    /// 감지된 프로바이더 (레지스트리 순서).
    private var enabledRuntimes: [any ProviderRuntime] {
        providers.orderedRuntimes.filter { providers.enabledIDs.contains($0.provider.id) }
    }

    /// AITool → providerID 매핑 (로컬 카드와 프로바이더 카드 병합용).
    /// gemini·qwen 은 대응 라이브 프로바이더가 없어 매핑하지 않는다(로컬 전용 카드로 표시).
    private static let toolToProvider: [AITool: String] = [
        .claudeCode: "claude", .codex: "codex", .cursor: "cursor", .copilot: "copilot",
    ]

    /// 프로바이더 카드에 흡수되지 않은 로컬 도구(사용 기록 있는 것만).
    private var localOnlySummaries: [ToolUsageSummary] {
        state.summaries.filter { summary in
            guard summary.usage.total > 0 else { return false }
            guard let providerID = Self.toolToProvider[summary.tool] else { return true }
            return !providers.enabledIDs.contains(providerID)
        }
    }

    /// providerID 에 매핑된 로컬 사용량 요약.
    private func localSummary(for providerID: String) -> ToolUsageSummary? {
        guard let tool = Self.toolToProvider.first(where: { $0.value == providerID })?.key else {
            return nil
        }
        let summary = state.summaries.first { $0.tool == tool }
        return (summary?.usage.total ?? 0) > 0 ? summary : nil
    }

    // MARK: 미사용 계정 숨김 (최근 7일)

    /// 로컬 로그 기준 최근 7일 사용 여부 — daily 는 30일치를 담으므로 7일로 슬라이스한다.
    private func hasRecentLocalUse(_ summary: ToolUsageSummary?) -> Bool {
        guard let summary else { return false }
        let key = UsageScanner.reportWindowStartKey()
        return summary.daily.contains { $0.key >= key && $0.value.total > 0 }
    }

    /// 쿼터 스냅샷의 사용 신호 — % 미터가 하나라도 0 보다 크면 true(다른 기기 사용 포함),
    /// % 미터가 전부 0 이거나 에러뿐이면 false, % 미터가 없어 판단 불가면 nil.
    private func quotaUsageSignal(_ snapshot: ProviderSnapshot?) -> Bool? {
        guard let snapshot else { return nil }
        if snapshot.errorMessage != nil { return false }
        var sawPercent = false
        for line in snapshot.lines {
            if case .progress(_, let used, _, .percent, _, _, _) = line {
                sawPercent = true
                if used > 0 { return true }
            }
        }
        return sawPercent ? false : nil
    }

    /// 이 프로바이더 계정이 최근 7일간 쓰였다고 볼 수 있는지.
    /// 확신이 없을 때(판단 근거 없음)는 숨기지 않는다.
    private func isRecentlyUsed(providerID: String) -> Bool {
        if hasRecentLocalUse(localSummary(for: providerID)) { return true }
        switch quotaUsageSignal(providers.snapshots[providerID]) {
        case .some(true): return true
        case .some(false):
            // 로컬 매핑이 없는 프로바이더는 쿼터 신호만으로 판정.
            // 로컬 매핑이 있으면 로컬도 쿼터도 조용한 것 — 미사용.
            return false
        case .none:
            return true  // 판단 불가 — 표시 유지
        }
    }

    /// 숨김 필터를 통과한 프로바이더 런타임.
    private var visibleRuntimes: [any ProviderRuntime] {
        guard settings.hideInactiveAccounts else { return enabledRuntimes }
        return enabledRuntimes.filter { isRecentlyUsed(providerID: $0.provider.id) }
    }

    /// 숨김 필터를 통과한 로컬 전용 도구.
    private var visibleLocalOnlySummaries: [ToolUsageSummary] {
        guard settings.hideInactiveAccounts else { return localOnlySummaries }
        return localOnlySummaries.filter { hasRecentLocalUse($0) }
    }

    /// 현재 숨겨진 계정 수.
    private var hiddenCount: Int {
        (enabledRuntimes.count - visibleRuntimes.count)
            + (localOnlySummaries.count - visibleLocalOnlySummaries.count)
    }

    /// "미사용 N개 숨김 — 모두 보기" / "미사용 계정 숨기기" 토글 라인.
    @ViewBuilder
    private var hiddenNotice: some View {
        if settings.hideInactiveAccounts, hiddenCount > 0 {
            Button {
                settings.hideInactiveAccounts = false
            } label: {
                Label("최근 7일 미사용 \(hiddenCount)개 숨김 — 모두 보기", systemImage: "eye.slash")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        } else if !settings.hideInactiveAccounts {
            Button {
                settings.hideInactiveAccounts = true
            } label: {
                Label("최근 7일 미사용 계정 숨기기", systemImage: "eye")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    /// "현재 활동" 행을 클릭해 열어 둔 진행 중 세션 상세 — nil 이면 대시보드.
    @State private var liveSessionDetail: SessionRecord?

    var body: some View {
        Group {
            if let liveSessionDetail {
                // 상세는 대시보드 자리를 대체한다 — 세션 기록 탭과 같은 방식
                // (팝오버라 시트/새 창을 띄우지 않는다).
                SessionTranscriptView(record: liveSessionDetail, isLive: true) {
                    self.liveSessionDetail = nil
                }
            } else if settings.dashboardMode == "each" {
                eachView
            } else {
                allView
            }
        }
        .overlay {
            if state.isScanning && state.lastScan == nil && liveSessionDetail == nil {
                ProgressView("스캔 중…").controlSize(.small)
            }
        }
    }

    // MARK: 전체 보기 — 통합 리스트 (기존 화면)

    private var allView: some View {
        ScrollView {
            VStack(spacing: Metrics.Space.section) {
                todayHeroCard
                CurrentActivitySection(onOpenSession: { liveSessionDetail = $0 })

                VStack(spacing: Metrics.Space.row) {
                    // 숨김 알림은 섹션 머리의 후행에 둔다 — 카드를 다 지나친 뒤에야
                    // "2개가 숨겨져 있었다"를 알게 되던 순서를 뒤집는다.
                    SectionHeader("프로바이더") { hiddenNotice }

                    ForEach(visibleRuntimes, id: \.provider.id) { runtime in
                        UnifiedProviderCard(
                            provider: runtime.provider,
                            snapshot: providers.snapshots[runtime.provider.id],
                            localSummary: localSummary(for: runtime.provider.id),
                            calibrator: state.quotaCalibrator
                        )
                    }

                    ForEach(visibleLocalOnlySummaries) { summary in
                        LocalToolCard(summary: summary)
                    }

                    if !providers.didDetect && enabledRuntimes.isEmpty {
                        Text("로컬 AI 도구 자격증명 감지 중…")
                            .font(.amonBody).foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(Metrics.Space.card)
        }
    }

    // MARK: 개별 보기 — 프로바이더 탭 + 전체 상세

    /// 탭 한 칸 — 감지된 프로바이더 또는 (프로바이더 미감지지만 기록 있는) 로컬 도구.
    private struct TabEntry: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let tint: Color
        let provider: Provider?
        let tool: AITool?
    }

    private var tabs: [TabEntry] {
        var out: [TabEntry] = []
        for runtime in visibleRuntimes {
            let p = runtime.provider
            out.append(TabEntry(
                id: p.id, title: p.displayName, symbol: p.symbol,
                tint: Color(hex: p.accentHex) ?? MenuBarContentView.accent,
                provider: p, tool: nil
            ))
        }
        for summary in visibleLocalOnlySummaries {
            out.append(TabEntry(
                id: "local:\(summary.tool.rawValue)", title: summary.tool.displayName,
                symbol: summary.tool.iconName, tint: summary.tool.tint,
                provider: nil, tool: summary.tool
            ))
        }
        return out
    }

    /// 저장된 선택이 사라졌으면(자격증명 변화 등) 첫 탭으로 폴백.
    private var selectedTabID: String {
        if tabs.contains(where: { $0.id == settings.selectedProviderTab }) {
            return settings.selectedProviderTab
        }
        return tabs.first?.id ?? ""
    }

    private var eachView: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if let tab = tabs.first(where: { $0.id == selectedTabID }) {
                        detail(for: tab)
                    } else {
                        Text("감지된 프로바이더 / 사용 기록이 없습니다")
                            .font(.amonBody).foregroundStyle(.tertiary)
                            .padding(.vertical, 24)
                    }

                    hiddenNotice
                }
                .padding(12)
            }
        }
    }

    /// 이 프로바이더에서 가장 빡빡한 미터의 심각도 — 정상이거나 판단 불가면 nil.
    /// 탭 위 점으로 표시해, 탭을 눌러보지 않아도 어디가 위험한지 알 수 있게 한다.
    private func severity(for providerID: String) -> MeterState.Severity? {
        guard let snapshot = providers.snapshots[providerID] else { return nil }
        var worst: MeterState.Severity = .normal
        for line in snapshot.lines {
            guard case .progress(_, let used, let limit, let format, let resetsAt, let periodMs, _) = line
            else { continue }
            let state = MeterEngine.state(
                used: used, limit: limit, format: format,
                resetsAt: resetsAt, periodDurationMs: periodMs
            )
            if state.severity == .critical { return .critical }
            if state.severity == .warning { worst = .warning }
        }
        return worst == .normal ? nil : worst
    }

    /// 로고만 남긴 아이콘 스트립. 선택된 탭만 가로로 늘어나 이름을 드러낸다.
    /// 이름은 바로 아래 카드 헤더에 이미 있으므로 상시 표시는 중복이었다.
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: TabEntry) -> some View {
        let isSelected = tab.id == selectedTabID
        // 로컬 전용 도구는 공식 로고가 없어 SF Symbol 폴백이다. 심볼은 로고보다 구분이
        // 약해서, 이들만 작은 라벨을 함께 남긴다.
        let isLocalOnly = tab.tool != nil

        Button {
            settings.selectedProviderTab = tab.id
        } label: {
            HStack(spacing: 6) {
                tabGlyph(tab, isLocalOnly: isLocalOnly, isSelected: isSelected)
                if isSelected {
                    Text(tab.title)
                        .font(.amonCaption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, isSelected ? 8 : 0)
            .frame(minWidth: Metrics.providerTab, maxHeight: .infinity)
            .frame(height: Metrics.providerTab)
            .foregroundStyle(isSelected ? tab.tint : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.inset, style: .continuous)
                    .fill(isSelected ? tab.tint.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.inset, style: .continuous)
                    .strokeBorder(
                        isSelected ? tab.tint.opacity(0.55) : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
            // 정체성(프로바이더 색)과 선택(액센트)이 서로 다른 채널을 쓴다.
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(MenuBarContentView.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                        .offset(y: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let severity = severity(for: tab.id) {
                    Circle()
                        .fill(severity == .critical ? Palette.statusRed : Palette.statusAmber)
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func tabGlyph(_ tab: TabEntry, isLocalOnly: Bool, isSelected: Bool) -> some View {
        if let logo = ProviderIcons.swiftUIImage(id: tab.id) {
            logo.resizable().scaledToFit().frame(width: 16, height: 16)
        } else if isLocalOnly, !isSelected {
            VStack(spacing: 1) {
                Image(systemName: tab.symbol).font(.system(size: 13, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: Metrics.providerTab - 4)
            }
        } else {
            Image(systemName: tab.symbol).font(.system(size: 16, weight: .semibold))
        }
    }

    /// 선택 탭의 전체 상세 — 프로바이더 탭은 쿼터 라인 + 확장 로컬 섹션,
    /// 로컬 전용 탭은 확장 로컬 카드.
    @ViewBuilder
    private func detail(for tab: TabEntry) -> some View {
        if let provider = tab.provider {
            UnifiedProviderCard(
                provider: provider,
                snapshot: providers.snapshots[provider.id],
                localSummary: localSummary(for: provider.id),
                calibrator: state.quotaCalibrator,
                expanded: true
            )
            // 라이브 활동은 Claude Code 훅 전용 데이터라 claude 탭에서만 보여준다.
            if provider.id == "claude" {
                CurrentActivitySection(onOpenSession: { liveSessionDetail = $0 })
            }
        } else if let tool = tab.tool,
                  let summary = state.summaries.first(where: { $0.tool == tool }) {
            LocalToolCard(summary: summary, expanded: true)
        }
    }

    /// 히어로 카드의 표시 축 — 카드 클릭으로 전체→입력→출력→캐시 순환.
    private enum HeroMetric: Int, CaseIterable {
        case total, input, output, cache

        var label: String {
            switch self {
            case .total: return "전체"
            case .input: return "입력"
            case .output: return "출력"
            case .cache: return "캐시"
            }
        }

        var next: HeroMetric {
            HeroMetric(rawValue: (rawValue + 1) % HeroMetric.allCases.count) ?? .total
        }
    }

    @State private var heroMetric: HeroMetric = .total

    private func heroValue(_ metric: HeroMetric) -> Int {
        switch metric {
        case .total: return state.grandToday
        case .input: return state.grandTodayInput
        case .output: return state.grandTodayOutput
        case .cache: return state.grandTodayCache
        }
    }

    /// 어제 같은 축의 합산 값 — 전일 대비 증감 계산용.
    private func yesterdayValue(_ metric: HeroMetric) -> Int {
        let y = state.grandYesterday
        switch metric {
        case .total: return y.total
        case .input: return y.input
        case .output: return y.output
        case .cache: return y.cacheRead + y.cacheWrite
        }
    }

    /// 전일 대비 증감 배지 — 어제보다 많이 썼으면 빨간 ↑, 적게 썼으면 파란 ↓ + 차이량.
    /// 차이가 0 이면 표시하지 않는다.
    @ViewBuilder
    private var dayDeltaBadge: some View {
        let today = heroValue(heroMetric)
        let yesterday = yesterdayValue(heroMetric)
        if today != yesterday {
            DayDeltaBadge(today: today, yesterday: yesterday)
        }
    }

    /// 오늘 전체 로컬 토큰 — 가장 크게 강조 (기존 사용량 화면의 히어로 유지).
    /// 카드를 클릭하면 큰 숫자가 전체/입력/출력/캐시로 순환하고, 아래 구성 행은
    /// 항상 표시된다(항목 클릭 시 해당 축으로 바로 이동).
    private var todayHeroCard: some View {
        VStack(spacing: 4) {
            Text(heroMetric == .total ? "오늘 사용량" : "오늘 사용량 · \(heroMetric.label)")
                .font(.amonBody)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(TokenFormat.grouped(heroValue(heroMetric)))
                    .font(.amonHero)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                dayDeltaBadge
            }
            .padding(.horizontal, 12)
            Text("토큰 · \(TokenFormat.compact(heroValue(heroMetric)))")
                .font(.amonCaption)
                .foregroundStyle(.tertiary)

            heroStrip
                .padding(.horizontal, 12)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) { heroMetric = heroMetric.next }
        }
        .help("클릭하면 전체 → 입력 → 출력 → 캐시 순환")
    }

    /// 히어로 하단 4칸 스트립 — 토큰 표와 같은 열 감각을 준다.
    private var heroStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(HeroMetric.allCases.enumerated()), id: \.element.rawValue) { index, metric in
                if index > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 0.5)
                }
                heroStat(metric)
            }
        }
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.inset, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    /// 스트립 한 칸 — 라벨 위, 값 아래. 활성 칸은 글자색이 아니라 밑줄로 표시해
    /// 네 숫자를 나란히 비교할 수 있게 둔다.
    private func heroStat(_ metric: HeroMetric) -> some View {
        let isActive = metric == heroMetric
        return Button {
            withAnimation(.snappy) { heroMetric = metric }
        } label: {
            VStack(spacing: 1) {
                Text(metric.label)
                    .font(.amonMicro)
                    .foregroundStyle(.tertiary)
                Text(TokenFormat.compact(heroValue(metric)))
                    .font(.amonCaption.weight(isActive ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(MenuBarContentView.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 14)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(metric.label) \(TokenFormat.grouped(heroValue(metric))) 토큰")
        .accessibilityLabel(metric.label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

}

// MARK: - 전일 대비 증감 배지

/// 히어로 숫자 옆 전일 대비 배지 — 화살표는 위아래로 살짝 떠다니고(bob),
/// 차이 숫자는 축 전환/재스캔 시 자릿수가 굴러가듯(numericText) 바뀐다.
/// 등장할 때는 스케일+페이드로 튀어나온다.
private struct DayDeltaBadge: View {
    let today: Int
    let yesterday: Int
    @State private var bob = false

    private var diff: Int { today - yesterday }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: diff > 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .contentTransition(.opacity)
                .offset(y: bob ? -1.5 : 1.5)
                .animation(
                    .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                    value: bob
                )
            Text(TokenFormat.compact(abs(diff)))
                .font(.amonCaption.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(diff > 0 ? Color.red : Color.blue)
        .animation(.snappy, value: diff)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
        .help("어제 \(TokenFormat.grouped(yesterday)) → 오늘 \(TokenFormat.grouped(today)) 토큰")
        .onAppear { bob = true }
    }
}

// MARK: - 통합 프로바이더 카드 (쿼터 + 추정 + 로컬)

private struct UnifiedProviderCard: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var providers: LiveProvidersManager
    let provider: Provider
    let snapshot: ProviderSnapshot?
    let localSummary: ToolUsageSummary?
    let calibrator: QuotaCalibrator
    /// 개별 보기(탭)에서 true — 로컬 섹션을 전체 상세(모델 전체·일자별·비용)로 펼친다.
    var expanded: Bool = false

    private var accent: Color { Color(hex: provider.accentHex) ?? MenuBarContentView.accent }

    /// 팀 시트 여부 — Cursor 팀처럼 per-user included-% 미터는 청구주기 리셋 직후엔
    /// 항상 0 이라(초과 사용 전까지 계속 0) 라이브 쿼터만으론 정보가 없다. 이때 실제
    /// 소비(로컬 로그)를 카드 상단에 강조해 "값이 안 나오는 것처럼" 보이지 않게 한다.
    private var isTeamSeat: Bool {
        snapshot?.plan?.lowercased().contains("team") == true
    }

    /// 팀 시트 실소비 강조 — 라이브 쿼터가 0 으로 도배돼도 실제 쓴 토큰을 먼저 보여준다.
    /// 소비 창(Cursor=대시보드 최근 7일)의 누적과 오늘을 액센트로 강조하고, 아래 LocalSection
    /// 은 상세를 유지한다. 소비 기록이 없으면(usage 0) 표시하지 않는다.
    @ViewBuilder
    private var teamConsumptionHighlight: some View {
        if isTeamSeat, let s = localSummary, s.usage.total > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(accent)
                Text("실사용").font(.amonCaption).foregroundStyle(.secondary)
                Text(TokenFormat.compact(s.usage.total))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                Text("토큰").font(.amonCaption).foregroundStyle(.secondary)
                Spacer()
                Text(s.today.total > 0 ? "오늘 \(TokenFormat.compact(s.today.total))" : "오늘 사용 없음")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .help("라이브 쿼터 included-% 는 청구주기 리셋 직후 0 입니다 — 실제 소비 토큰(최근 창) 기준")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // 팀 시트는 라이브 쿼터(아래 %)가 초기엔 전부 0 이라, 실제 소비를 먼저 강조.
            teamConsumptionHighlight
            if let snapshot {
                if let warning = snapshot.warning {
                    warningRow(warning)
                }
                // 각 그래프의 제목·막대·상태 컨트롤을 한 덩어리로 읽을 수 있도록
                // 그래프 사이 간격은 카드의 일반 요소 간격보다 넓게 둔다.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(snapshot.lines.enumerated()), id: \.offset) { _, line in
                        LineRow(
                            line: line, accent: accent, estimate: estimate(for: line),
                            menuBarSlot: menuBarSlot(for: line),
                            onToggleMenuBar: isProgress(line) ? { selectMeterForMenuBar(line.label) } : nil
                        )
                    }
                }
            } else {
                Text("쿼터 불러오는 중…").font(.amonCaption).foregroundStyle(.tertiary)
            }
            if let localSummary {
                LocalSection(summary: localSummary, expanded: expanded)
            }
            if !provider.links.isEmpty {
                linksRow
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        )
    }

    private func isProgress(_ line: MetricLine) -> Bool {
        if case .progress = line { return true }
        return false
    }

    /// 이 미터가 현재 메뉴바에 표시 중인지 — 명시 선택뿐 아니라 대표 미터(자동)도
    /// 포함한다. 화면을 처음 열었을 때 지금 메뉴바에 떠 있는 상태가 선택돼 보이게 한다.
    /// (설정을 바꾸지 않고 표시만 반영 — 대표 선택을 조용히 고정으로 바꾸지 않는다.)
    private func menuBarSlot(for line: MetricLine) -> Int? {
        guard isProgress(line), settings.menuBarQuotaEnabled else { return nil }

        // 메뉴바는 provider별 슬롯을 모두 합쳐 표시하므로 팝업도 마지막으로 선택한
        // 단일 provider가 아니라 각 provider의 실제 슬롯을 기준으로 선택 상태를 그린다.
        let slots = settings.menuBarQuotaMeterSlots(for: provider.id)
        if slots[0] == line.label { return 1 }
        if slots[1] == line.label { return 2 }

        // 자동 선택 모드도 실제 메뉴바에 표시 중인 대표 미터를 ON 상태로 보여준다.
        if settings.menuBarQuotaProviderID.isEmpty {
            guard providers.tightestSessionUsage?.id == provider.id,
                  providers.menuBarUsage(id: provider.id)?.meterLabel == line.label
            else { return nil }
            return 1
        }

        // 구버전의 provider 고정 + 대표 미터 설정(명시 슬롯 없음)도 실제 표시와 맞춘다.
        guard settings.menuBarQuotaProviderID == provider.id else { return nil }
        guard slots.allSatisfy(\.isEmpty),
              providers.menuBarUsage(id: provider.id)?.meterLabel == line.label
        else { return nil }
        return 1
    }

    /// 그래프 하단의 `상태창 보기` 토글로 표시 항목을 추가하거나 해제한다.
    /// 저장 배열은 최대 2개 선택을 보관할 뿐이며 실제 위/아래 순서는 그래프 순서로 결정한다.
    private func selectMeterForMenuBar(_ label: String) {
        // 자동 선택으로 현재 표시 중인 미터를 끄면 메뉴바 쿼터 표시 전체를 끈다.
        if settings.menuBarQuotaProviderID.isEmpty,
           settings.menuBarQuotaEnabled,
           providers.tightestSessionUsage?.id == provider.id,
           providers.menuBarUsage(id: provider.id)?.meterLabel == label {
            settings.menuBarQuotaEnabled = false
            return
        }

        var slots = settings.menuBarQuotaMeterSlots(for: provider.id)
        if slots[0] == label {
            slots[0] = slots[1]
            slots[1] = ""
        } else if slots[1] == label {
            slots[1] = ""
        } else if slots[0].isEmpty {
            slots[0] = label
        } else if slots[1].isEmpty {
            slots[1] = label
        } else {
            slots[1] = label
        }
        settings.menuBarQuotaProviderID = provider.id
        settings.setMenuBarQuotaMeterSlots(slots, for: provider.id)
        settings.menuBarQuotaEnabled = true
    }

    /// % 미터에 병기할 토큰 추정 (캘리브레이션 환율이 있을 때만).
    private func estimate(for line: MetricLine) -> (text: String, help: String)? {
        guard case .progress(let label, let used, _, .percent, _, _, _) = line,
              QuotaCalibrator.calibratableLabels.contains(label),
              let text = calibrator.estimateText(providerID: provider.id, label: label, usedPercent: used)
        else { return nil }
        return (text, calibrator.estimateHelp(providerID: provider.id, label: label))
    }

    private var header: some View {
        HStack(spacing: 8) {
            // 공식 로고가 있으면 로고(템플릿+액센트 tint), 없으면 SF Symbol 폴백.
            if let logo = ProviderIcons.swiftUIImage(id: provider.id) {
                logo
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(accent)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: provider.symbol)
                    .foregroundStyle(accent)
                    .frame(width: 16)
            }
            Text(provider.displayName)
                .font(.amonSection)
            if let plan = snapshot?.plan, !plan.isEmpty {
                Text(plan)
                    .font(.amonCaption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .separatorColor).opacity(0.4)))
            }
            Spacer()
            if let refreshed = snapshot?.refreshedAt {
                Text(refreshed.formatted(date: .omitted, time: .shortened))
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .help("이 프로바이더 스냅샷 조회 시각")
            }
        }
    }

    private var linksRow: some View {
        HStack(spacing: 8) {
            ForEach(provider.links, id: \.url) { link in
                Button {
                    if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 3) {
                        Text(link.label)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(link.url)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.amonCaption)
                .foregroundStyle(.orange)
            Text(text)
                .font(.amonCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 카드 내 로컬 로그 섹션

/// 프로바이더 카드에 합쳐지는 로컬 소비 요약 — openusage 스팬드 타일의 자리.
/// `expanded` 면(개별 보기 탭) 모델 전체 목록·최근 7일·비용까지 펼친다.
private struct LocalSection: View {
    let summary: ToolUsageSummary
    var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("로컬 로그", systemImage: "internaldrive")
            // 접힘·펼침이 같은 4열 표를 쓴다 — 펼침은 행만 늘어난다.
            TokenGrid(summary: summary, expanded: expanded)
        }
        .padding(.top, 2)
    }
}

// MARK: - 모델별 누적 요약 (LocalSection · LocalToolCard 공용)

/// `ToolUsageSummary.models` 를 "opus-4-8 81% · sonnet-5 7%" 한 줄로 축약한다.
/// hover 시 전체 모델·토큰 목록을 툴팁으로 보여준다.
enum ModelBreakdown {
    /// 표시용 모델명 — 공통 접두어를 걷어내 popover 폭에 맞춘다.
    static func shortName(_ model: String) -> String {
        if model == "unknown" { return "(모델 미상)" }
        var s = model
        for prefix in ["claude-", "models/"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        return s
    }

    /// 상위 2개 모델 + 점유율 한 줄 요약. 모델 정보가 없으면 nil.
    static func summaryText(_ summary: ToolUsageSummary) -> String? {
        let total = summary.usage.total
        guard total > 0, !summary.models.isEmpty else { return nil }
        let top = summary.models.sorted { $0.value > $1.value }.prefix(2)
        let parts = top.map { model, tokens -> String in
            let pct = Int((Double(tokens) / Double(total) * 100).rounded())
            return "\(shortName(model)) \(pct)%"
        }
        return parts.joined(separator: " · ")
    }

    /// 툴팁 — 전체 모델을 토큰 내림차순으로 나열.
    static func helpText(_ summary: ToolUsageSummary) -> String {
        summary.models
            .sorted { $0.value > $1.value }
            .map { "\(shortName($0.key)): \(TokenFormat.compact($0.value))" }
            .joined(separator: "\n")
    }
}

// MARK: - 로컬 전용 카드 (프로바이더 미감지 도구 — OpenCode 등)

private struct LocalToolCard: View {
    let summary: ToolUsageSummary
    /// 개별 보기(탭)에서 true — 로컬 상세(모델 전체·일자별·비용)를 펼친다.
    var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: summary.tool.iconName)
                    .foregroundStyle(summary.tool.tint)
                    .frame(width: 16)
                Text(summary.tool.displayName)
                    .font(.amonSection)
                Text("로컬")
                    .font(.amonCaption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .separatorColor).opacity(0.4)))
                Spacer()
                Text(TokenFormat.compact(summary.today.total))
                    .font(.system(size: 17, design: .rounded).weight(.bold))
                    .foregroundStyle(summary.today.total > 0 ? summary.tool.tint : Color.secondary)
                    .help("오늘 토큰")
            }

            if let note = summary.note {
                Label(note, systemImage: summary.pathExists ? "info.circle" : "exclamationmark.triangle")
                    .font(.amonCaption)
                    .foregroundStyle(summary.pathExists ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }

            // 프로바이더 카드와 같은 4열 표를 쓴다 — 로컬 전용 도구라고 형태가 달라지지 않는다.
            TokenGrid(summary: summary, expanded: expanded)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - MetricLine 렌더 (페이스 미터 + 추정 라인)

private struct LineRow: View {
    let line: MetricLine
    let accent: Color
    /// % 미터에 병기할 캘리브레이션 토큰 추정 (없으면 nil).
    var estimate: (text: String, help: String)?
    /// 이 미터가 메뉴바 표시 대상으로 선택돼 있는지. nil 이면 미선택.
    var menuBarSlot: Int?
    /// 그래프 하단 `상태창 보기` 토글 액션. progress 미터에만 제공한다.
    var onToggleMenuBar: (() -> Void)? = nil

    /// 리셋 크레딧 만료 경고 창 — 24시간 (openusage `expiryWarningWindow`).
    private static let expiryWarningWindow: TimeInterval = 24 * 60 * 60

    @State private var hovering = false

    /// 메뉴바 표시 토글 — 스위치 대신 핀.
    ///
    /// 고정돼 있으면 항상 보이고, 아니면 hover 할 때만 나타난다. 동작(슬롯 최대 2개,
    /// 자동 선택 반영)은 이전 스위치와 동일하다.
    private func menuBarPin(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: menuBarSlot == nil ? "pin" : "pin.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(menuBarSlot == nil ? Color.secondary : accent)
                .opacity(menuBarSlot == nil ? (hovering ? 0.7 : 0) : 1)
        }
        .buttonStyle(.plain)
        .frame(width: 14)
        .help(menuBarSlot == nil ? "이 그래프를 메뉴바에 표시" : "메뉴바 표시에서 제거")
        .accessibilityLabel("메뉴바 표시")
        .accessibilityAddTraits(menuBarSlot == nil ? [] : .isSelected)
    }

    var body: some View {
        switch line {
        case .progress(let label, let used, let limit, let format, let resetsAt, let periodMs, _):
            meterRow(label: label, used: used, limit: limit, format: format,
                     resetsAt: resetsAt, periodMs: periodMs)

        case .values(let label, let values, _, let expiriesAt, _):
            valuesRow(label: label, values: values, expiriesAt: expiriesAt)

        case .badge(let label, let text, let colorHex, _):
            if line.isError {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill").font(.amonCaption).foregroundStyle(.red)
                    Text(text).font(.amonBody).foregroundStyle(.red).lineLimit(2)
                }
            } else {
                HStack {
                    Text(label).font(.amonBody).foregroundStyle(.secondary)
                    Spacer()
                    Text(text)
                        .font(.amonCaption.weight(.semibold))
                        .foregroundStyle(Color(hex: colorHex) ?? .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill((Color(hex: colorHex) ?? .gray).opacity(0.14)))
                }
            }

        case .text(let label, let value, _, _):
            HStack {
                Text(label).font(.amonBody).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.amonBody.weight(.medium)).monospacedDigit()
            }
        }
    }

    // MARK: progress (페이스 미터)

    @ViewBuilder
    private func meterRow(
        label: String, used: Double, limit: Double, format: ProgressFormat,
        resetsAt: Date?, periodMs: Int?
    ) -> some View {
        let state = MeterEngine.state(used: used, limit: limit, format: format,
                                      resetsAt: resetsAt, periodDurationMs: periodMs)
        let tick = MeterEngine.paceTick(state: state, resetsAt: resetsAt, periodDurationMs: periodMs)
        let trailing = MeterEngine.trailingResetText(used: used, resetsAt: resetsAt, periodDurationMs: periodMs)
        let isFresh = MeterEngine.isFreshSessionWindow(used: used, resetsAt: resetsAt, periodDurationMs: periodMs)

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.amonSection)
                    .foregroundStyle(.primary)
                Spacer()
                Text(MetricFormat.progressTrailing(used: used, limit: limit, format: format))
                    .font(.amonBody.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(remainingHelp(used: used, limit: limit, format: format))
            }

            // 막대와 핀을 한 행에 둔다 — 설정 컨트롤을 읽기 전용 상태 줄에서 걷어낸다.
            HStack(spacing: 8) {
                Bar(fraction: MetricFormat.progressFraction(used: used, limit: limit, format: format),
                    severity: state.severity, accent: accent, tick: tick)
                    .help(state.tooltip ?? "")
                if let onToggleMenuBar {
                    menuBarPin(action: onToggleMenuBar)
                }
            }

            HStack(spacing: 6) {
                if let status = state.statusText {
                    HStack(spacing: 3) {
                        Image(systemName: state.severity == .critical ? "flame.fill" : "gauge.medium")
                            .font(.amonMicro)
                        Text(status)
                    }
                    .font(.amonCaption.weight(.medium))
                    .foregroundStyle(state.severity == .critical ? Palette.statusRed : Palette.statusAmber)
                    .help(state.tooltip ?? "")
                }
                if let trailing {
                    Label(trailing, systemImage: "clock")
                        .font(.amonBody.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help(isFresh ? MeterEngine.freshSessionTooltip : exactResetHelp(resetsAt))
                }
                Spacer()
            }

            // %→토큰 추정 라인 (캘리브레이션 환율 확보 시).
            if let estimate {
                Text(estimate.text)
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .help(estimate.help)
            }
        }
        .onHover { hovering = $0 }
        // 제목·막대·상태·토글 전체가 하나의 선택 영역으로 읽히도록 안쪽 여백을 확보한다.
        // 미선택 행에도 같은 여백을 유지해 토글 시 카드 폭과 그래프 위치가 흔들리지 않게 한다.
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if menuBarSlot != nil {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(0.55), lineWidth: 1)
                    }
            }
        }
    }

    private func remainingHelp(used: Double, limit: Double, format: ProgressFormat) -> String {
        switch format {
        case .percent:
            return "\(Int(max(0, 100 - used).rounded()))% 남음"
        case .dollars:
            return MetricFormat.dollars(max(0, limit - used)) + " 남음"
        case .count(let suffix):
            let left = Int(max(0, limit - used).rounded())
            return suffix.isEmpty ? "\(left) 남음" : "\(left) \(suffix) 남음"
        }
    }

    private func exactResetHelp(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        return "리셋: " + resetsAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: values (만료 경고·전체 자릿수 툴팁)

    @ViewBuilder
    private func valuesRow(label: String, values: [MetricValue], expiriesAt: [Date]) -> some View {
        let soonest = expiriesAt.min()
        let imminent = soonest.map { $0.timeIntervalSinceNow <= Self.expiryWarningWindow } ?? false

        HStack {
            Text(label).font(.amonBody).foregroundStyle(.secondary)
            Spacer()
            if imminent {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(expiryHelp(expiriesAt))
            }
            Text(MetricFormat.values(values))
                .font(.amonBody.weight(.medium))
                .monospacedDigit()
                .help(valuesHelp(values: values, expiriesAt: expiriesAt))
        }
    }

    private func valuesHelp(values: [MetricValue], expiriesAt: [Date]) -> String {
        if !expiriesAt.isEmpty { return expiryHelp(expiriesAt) }
        guard MetricFormat.hasAbbreviation(values) else { return "" }
        return MetricFormat.fullValues(values)
    }

    private func expiryHelp(_ expiriesAt: [Date]) -> String {
        let sorted = expiriesAt.sorted()
        guard !sorted.isEmpty else { return "" }
        if sorted.count == 1, let d = MeterEngine.compactDuration(sorted[0].timeIntervalSinceNow) {
            return "리셋 만료까지 \(d)"
        }
        let entries = sorted.enumerated().compactMap { i, date -> String? in
            MeterEngine.compactDuration(date.timeIntervalSinceNow).map { "\(i + 1). \($0)" }
        }
        guard !entries.isEmpty else { return "" }
        return (["리셋 만료까지:"] + entries).joined(separator: "\n")
    }
}

/// 얇은 진행 막대 — 페이스 상태 색 + 균등 페이스 틱 (openusage 미터의 축약).
private struct Bar: View {
    let fraction: Double
    let severity: MeterState.Severity
    let accent: Color
    let tick: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.35))
                Capsule().fill(barColor).frame(width: max(3, geo.size.width * fraction))
                if let tick {
                    Rectangle()
                        .fill(Color(nsColor: .labelColor).opacity(0.45))
                        .frame(width: 1.5, height: 10)
                        .offset(x: geo.size.width * tick - 0.75, y: -2)
                }
            }
        }
        .frame(height: 6)
    }

    private var barColor: Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return accent
        }
    }
}

extension Color {
    /// "#RRGGBB" 또는 "RRGGBB" hex → Color. 실패 시 nil.
    init?(hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
