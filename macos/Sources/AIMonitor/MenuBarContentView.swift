import SwiftUI

/// 상태바 아이콘을 클릭하면 나타나는 패널.
///
/// 헤더(제목·보기 방식·새로고침) + 본문 + 오른쪽 화면 내비게이션 + 푸터.
struct MenuBarContentView: View {
    /// SwiftUI 루트와 AppKit `NSPopover`가 함께 쓰는 실제 팝업 크기.
    ///
    /// 오른쪽 내비게이션 레일을 없애면서 본문이 팝오버 전체 폭을 쓴다. 레일은 항목 3개에
    /// 55pt(전체의 11%)를 상시 점유하면서 제목과 같은 정보("지금 대시보드에 있다")를
    /// 중복 표시했다. 화면 전환은 헤더로 옮겼다 — 제목이 곧 선택된 화면이다.
    static let preferredSize = CGSize(width: 496, height: 540)
    private static let mainContentWidth: CGFloat = 496

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var providers: LiveProvidersManager
    @EnvironmentObject private var settings: AppSettings

    /// 팝오버 화면 — 통합 대시보드(로컬 사용량 + 라이브 쿼터, 현재 활동 섹션 포함) ·
    /// 세션 기록(종료된 세션) · 설정.
    enum Screen: Hashable, CaseIterable { case dashboard, history, settings }
    @State private var screen: Screen = .dashboard

    /// 브랜드 1차 색상 — Interactive Violet. docs/DESIGN.html 참조. 토큰 출처: Palette.accent
    static let accent = Palette.accent

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if state.availableUpdate != nil {
                updateBanner
                Divider()
            }

            // 상태 표시줄은 상태 표시줄 자리에 — 이전엔 현재 활동과 첫 카드 사이에 끼어 있었다.
            if screen == .dashboard {
                dashboardMeta
                Divider()
            }

            switch screen {
            case .dashboard: DashboardView()
            case .history: SessionHistoryView()
            case .settings: SettingsView()
            }

            Divider()
            footer
        }
        .frame(width: Self.mainContentWidth)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .task { state.scanOnAppear() }
    }

    /// 새 버전 감지 시 상단 배너 (알림 → 클릭 시 설치).
    private var updateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Self.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("새 버전 v\(state.availableUpdate?.version ?? "") 있음")
                    .font(.amonBody.weight(.semibold))
                if let err = state.updateError {
                    Text(err).font(.amonCaption).foregroundStyle(.orange).lineLimit(1)
                } else {
                    Text("현재 \(AppInfo.shortVersion)")
                        .font(.amonCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                state.installUpdate()
            } label: {
                if state.isInstallingUpdate {
                    ProgressView().controlSize(.small)
                } else {
                    Text("설치")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.accent)
            .controlSize(.small)
            .disabled(state.isInstallingUpdate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Self.accent.opacity(0.08))
    }

    /// 새로고침 진행 여부(스피너 애니메이션용) — 로컬 스캔·쿼터 조회 둘 다 반영.
    private var isBusy: Bool {
        state.isScanning || providers.isRefreshing
    }

    /// 제목이 곧 선택된 화면이다 — 누르면 다음 화면으로 넘어가고, 옆의 아이콘 두 개가
    /// 나머지 화면이다. 아이콘 스트립·모드 토글과 같은 문법(아이콘을 두되 선택된 것만
    /// 라벨을 펼친다)의 가장 큰 단계.
    @State private var titleHovering = false

    private var screenSwitcher: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { screen = screen.next }
            } label: {
                HStack(spacing: 3) {
                    Text(headerTitle)
                        .font(.amonTitle)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(titleHovering ? 1 : 0)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                        .fill(titleHovering ? Color.secondary.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { titleHovering = $0 }
            .help("다음 화면으로 전환")
            .accessibilityLabel("현재 화면 \(headerTitle), 누르면 전환")

            HStack(spacing: 3) {
                ForEach(Screen.allCases.filter { $0 != screen }, id: \.self) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { screen = item }
                    } label: {
                        Image(systemName: item.symbolName)
                            .font(.amonBody)
                            .frame(width: 28, height: 26)
                            .foregroundStyle(.tertiary)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                                    .fill(Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.helpText)
                    .accessibilityLabel(item.title)
                }
            }
        }
        .layoutPriority(1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            screenSwitcher

            Spacer()

            if screen == .dashboard {
                dashboardModeToggle
            }

            if screen != .settings {
                // 새로고침 — 로컬 스캔 + 라이브 쿼터 재조회를 함께.
                Button {
                    state.scan()
                    Task { await providers.manualRefresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isBusy ? 360 : 0))
                        .animation(
                            isBusy
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .default,
                            value: isBusy
                        )
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help("다시 스캔 + 쿼터 새로고침")
                .accessibilityLabel("다시 스캔 및 쿼터 새로고침")
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// macOS segmented Picker는 좁은 폭에서 접근성 라벨까지 시각적으로 렌더링해
    /// 한글을 한 글자씩 세로로 압축한다. 아이콘 버튼 두 개로 같은 2-state 선택을 표현한다.
    private var dashboardModeToggle: some View {
        HStack(spacing: 2) {
            dashboardModeButton(
                mode: "all",
                symbol: "chart.bar.xaxis",
                short: "전체",
                label: "전체 종합",
                help: "모든 프로바이더의 AI 사용량을 종합해 보기"
            )
            dashboardModeButton(
                mode: "each",
                symbol: "rectangle.3.group.fill",
                short: "개별",
                label: "프로바이더별",
                help: "프로바이더별 AI 사용량을 개별로 보기"
            )
        }
        .padding(2)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 사용량 보기")
        .accessibilityValue(settings.dashboardMode == "all" ? "전체" : "개별")
    }

    /// 선택된 쪽만 라벨을 펼친다. 두 심볼(막대 그래프 / 카드 묶음)은 나란히 놓으면
    /// 구분이 거의 안 돼, 채움색만으로 상태를 판단해야 했다.
    private func dashboardModeButton(
        mode: String, symbol: String, short: String, label: String, help: String
    ) -> some View {
        let selected = settings.dashboardMode == mode
        return Button {
            settings.dashboardMode = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                if selected {
                    Text(short)
                        .font(.amonMicro.weight(.semibold))
                        .fixedSize()
                }
            }
            .padding(.horizontal, selected ? 7 : 0)
            .frame(minWidth: 26, maxHeight: .infinity)
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Self.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var headerTitle: String {
        screen.title
    }

    /// 쿼터 감지 수 + 마지막 갱신 시각.
    private var dashboardMeta: some View {
        HStack(spacing: 5) {
            Text("쿼터 감지 \(providers.enabledIDs.count)/\(providers.orderedRuntimes.count)")
                .font(.amonCaption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let last = providers.lastRefresh {
                Text("· 갱신 \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            if let last = state.lastScan {
                Text("스캔 \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(" ")
                    .font(.amonCaption)
            }
            Spacer()
            if screen == .dashboard, state.grandTotal > 0 {
                Text("전체 누적 \(TokenFormat.compact(state.grandTotal))")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .help("로컬 로그 기준 전체 누적 \(TokenFormat.grouped(state.grandTotal)) 토큰")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private extension MenuBarContentView.Screen {
    /// 제목을 눌렀을 때 넘어갈 다음 화면 — 대시보드 → 세션 → 설정 → 대시보드.
    var next: MenuBarContentView.Screen {
        let all = MenuBarContentView.Screen.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var title: String {
        switch self {
        case .dashboard: return "AI 사용량"
        case .history: return "세션 정보"
        case .settings: return "설정"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }

    var helpText: String {
        switch self {
        case .dashboard: return "AI 사용량과 프로바이더 쿼터 보기"
        case .history: return "종료된 AI 세션 정보 보기"
        case .settings: return "amon 설정 열기"
        }
    }
}

#Preview {
    MenuBarContentView()
        .environmentObject(AppState())
        .environmentObject(AppSettings())
        .environmentObject(LiveProvidersManager())
}
