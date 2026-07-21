import SwiftUI

/// 상태바 아이콘을 클릭하면 나타나는 패널.
///
/// 헤더(제목·보기 방식·새로고침) + 본문 + 오른쪽 화면 내비게이션 + 푸터.
struct MenuBarContentView: View {
    /// SwiftUI 루트와 AppKit `NSPopover`가 함께 쓰는 실제 팝업 크기.
    /// 오른쪽 내비게이션을 추가할 때 한쪽만 바뀌어 내용이 압축되지 않게 단일 기준으로 둔다.
    static let preferredSize = CGSize(width: 496, height: 540)
    private static let mainContentWidth: CGFloat = 440
    private static let navigationRailWidth: CGFloat = 55

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var providers: LiveProvidersManager
    @EnvironmentObject private var settings: AppSettings

    /// 팝오버 화면 — 통합 대시보드(로컬 사용량 + 라이브 쿼터, 현재 활동 섹션 포함) ·
    /// 세션 기록(종료된 세션) · 설정.
    enum Screen: Hashable, CaseIterable { case dashboard, history, settings }
    @State private var screen: Screen = .dashboard

    /// 브랜드 1차 색상 — Interactive Violet (#6161ff). docs/DESIGN.html 참조.
    static let accent = Color(red: 0x61 / 255, green: 0x61 / 255, blue: 0xff / 255)

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()

                if state.availableUpdate != nil {
                    updateBanner
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

            Divider()
            navigationRail
        }
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

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.amonTitle)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            if screen == .dashboard {
                dashboardModeToggle
            }

            Spacer()

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
                label: "전체 종합",
                help: "모든 프로바이더의 AI 사용량을 종합해 보기"
            )
            dashboardModeButton(
                mode: "each",
                symbol: "rectangle.3.group.fill",
                label: "프로바이더별",
                help: "프로바이더별 AI 사용량을 개별로 보기"
            )
        }
        .padding(2)
        .frame(width: 68, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 사용량 보기")
        .accessibilityValue(settings.dashboardMode == "all" ? "전체" : "개별")
    }

    private func dashboardModeButton(mode: String, symbol: String, label: String, help: String) -> some View {
        let selected = settings.dashboardMode == mode
        return Button {
            settings.dashboardMode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .help(help)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Self.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 팝오버 오른쪽의 화면 전환 아이콘. 선택된 화면은 브랜드 색 배경으로 표시한다.
    private var navigationRail: some View {
        VStack(spacing: 8) {
            ForEach(Screen.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        screen = item
                    }
                } label: {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(screen == item ? Self.accent : Color.secondary)
                        .help(item.helpText)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(screen == item ? Self.accent.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(item.helpText)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(screen == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: Self.navigationRailWidth)
    }

    private var headerTitle: String {
        screen.title
    }

    private var footer: some View {
        HStack {
            if let last = state.lastScan {
                Text("스캔: \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(" ")
                    .font(.amonCaption)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private extension MenuBarContentView.Screen {
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
        case .settings: return "A-mon 설정 열기"
        }
    }
}

#Preview {
    MenuBarContentView()
        .environmentObject(AppState())
        .environmentObject(AppSettings())
        .environmentObject(LiveProvidersManager())
}
