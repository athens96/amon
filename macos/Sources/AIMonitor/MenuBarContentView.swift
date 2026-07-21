import SwiftUI

/// 메뉴바 아이콘에서 열리는 A-mon 워크스페이스.
/// 좌측 내비게이션과 넓은 콘텐츠 영역을 분리해 세 화면의 구조를 일관되게 유지한다.
struct MenuBarContentView: View {
    static let preferredSize = CGSize(width: 720, height: 600)
    private static let sidebarWidth: CGFloat = 164

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var providers: LiveProvidersManager
    @EnvironmentObject private var settings: AppSettings

    enum Screen: Hashable, CaseIterable { case dashboard, history, settings }
    @State private var screen: Screen = .dashboard

    static let accent = Color(red: 0x12 / 255, green: 0x91 / 255, blue: 0x78 / 255)
    static let warmAccent = Color(red: 0xef / 255, green: 0x7d / 255, blue: 0x4a / 255)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 0.5)

            VStack(spacing: 0) {
                topBar

                if state.availableUpdate != nil {
                    updateBanner
                }

                Group {
                    switch screen {
                    case .dashboard: DashboardView()
                    case .history: SessionHistoryView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.42))
            }
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .task { state.scanOnAppear() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            VStack(spacing: 4) {
                ForEach(Screen.allCases, id: \.self) { item in
                    navigationButton(item)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 22)

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isScanning ? Self.warmAccent : Self.accent)
                        .frame(width: 7, height: 7)
                    Text(state.isScanning ? "데이터 읽는 중" : "로컬 수집 정상")
                        .font(.amonCaption.weight(.medium))
                }
                if let last = state.lastScan {
                    Text("마지막 스캔 \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.amonCaption)
                        .foregroundStyle(.tertiary)
                }
                Text("v\(AppInfo.shortVersion)")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
        }
        .frame(width: Self.sidebarWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var brand: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.accent)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text("A-mon")
                    .font(.system(size: 16, weight: .bold))
                Text("AI activity")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
    }

    private func navigationButton(_ item: Screen) -> some View {
        let selected = screen == item
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { screen = item }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(item.title)
                    .font(.amonBody.weight(selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Self.accent : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Self.accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.helpText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.title)
                    .font(.system(size: 20, weight: .bold))
                Text(screen.subtitle)
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if screen == .dashboard {
                dashboardModeToggle
            }

            if screen != .settings {
                refreshButton
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
        }
    }

    private var isBusy: Bool { state.isScanning || providers.isRefreshing }

    private var refreshButton: some View {
        Button {
            state.scan()
            Task { await providers.manualRefresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .rotationEffect(.degrees(isBusy ? 360 : 0))
                .animation(
                    isBusy ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                    value: isBusy
                )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isBusy)
        .help("사용량과 쿼터 새로고침")
    }

    private var dashboardModeToggle: some View {
        HStack(spacing: 2) {
            dashboardModeButton(mode: "all", symbol: "square.grid.2x2", help: "전체 보기")
            dashboardModeButton(mode: "each", symbol: "rectangle.3.group", help: "도구별 보기")
        }
        .padding(2)
        .frame(width: 68, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func dashboardModeButton(mode: String, symbol: String, help: String) -> some View {
        let selected = settings.dashboardMode == mode
        return Button { settings.dashboardMode = mode } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Self.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var updateBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Self.warmAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("A-mon v\(state.availableUpdate?.version ?? "") 사용 가능")
                    .font(.amonBody.weight(.semibold))
                Text(state.updateError ?? "현재 버전 \(AppInfo.shortVersion)")
                    .font(.amonCaption)
                    .foregroundStyle(state.updateError == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            Button("설치") { state.installUpdate() }
                .buttonStyle(.borderedProminent)
                .tint(Self.warmAccent)
                .controlSize(.small)
                .disabled(state.isInstallingUpdate)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(Self.warmAccent.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Self.warmAccent.opacity(0.22)).frame(height: 0.5)
        }
    }
}

private extension MenuBarContentView.Screen {
    var title: String {
        switch self {
        case .dashboard: return "Overview"
        case .history: return "Sessions"
        case .settings: return "Preferences"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: return "오늘의 사용량과 남은 쿼터"
        case .history: return "최근 작업 흐름과 대화 기록"
        case .settings: return "수집 경로와 연결 관리"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }

    var helpText: String {
        switch self {
        case .dashboard: return "사용량과 쿼터"
        case .history: return "세션 기록"
        case .settings: return "A-mon 설정"
        }
    }
}

#Preview {
    MenuBarContentView()
        .environmentObject(AppState())
        .environmentObject(AppSettings())
        .environmentObject(LiveProvidersManager())
}
