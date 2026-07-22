import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 설정 화면 — 3개 카테고리로 나뉜다:
/// 기본 설정(자동 실행·업데이트·알림·메뉴바 표시) / 로컬 데이터 설정(도구별 로그
/// 경로) / 서버 연동 설정(URL·유저 키 + 라이브 세션·에이전트 대시보드 공유).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // ── 기본 설정 ────────────────────────────────────────────
                SettingsCategoryHeader(icon: "gearshape", title: "기본 설정")

                LaunchAtLoginRow()

                AutoUpdateRow()

                // IconPickerRow() — 내장 아이콘 5종·커스텀 파일 픽커는 숨김.
                // 메뉴바 아이콘이 프로바이더 공식 로고(ProviderIcons)를 따라가면서
                // 수동 선택이 무의미해졌다. 프로바이더 미감지 시 폴백으로만 쓰인다.

                QuotaAlertsRow()

                MenuBarQuotaRow()

                Divider()

                // ── 로컬 데이터 설정 ─────────────────────────────────────
                SettingsCategoryHeader(icon: "folder", title: "로컬 데이터 설정")

                Text("각 도구의 로그 폴더를 지정하세요. 변경 후 아래 '다시 스캔'을 누르면 반영됩니다.")
                    .font(.amonBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(AITool.allCases) { tool in
                    PathEditor(tool: tool)
                }

                Button {
                    state.scan()
                } label: {
                    HStack {
                        Spacer()
                        Label("다시 스캔", systemImage: "arrow.clockwise")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MenuBarContentView.accent)
                .disabled(state.isScanning)
                .padding(.top, 4)

                Divider()

                // ── 업데이트 및 로컬 라이브 설정 ─────────────────────────
                SettingsCategoryHeader(
                    icon: "antenna.radiowaves.left.and.right", title: "업데이트 및 라이브 설정"
                )

                ServerSection()

                LiveActivityRow()

                HStack {
                    Spacer()
                    Text("A-mon \(AppInfo.version)")
                        .font(.amonCaption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(16)
        }
    }
}

/// 설정 카테고리 헤더 — 액센트 아이콘 + 섹션 폰트 (기존 서버 연동 헤더 스타일).
private struct SettingsCategoryHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(MenuBarContentView.accent)
                .frame(width: 16)
            Text(title)
                .font(.amonSection)
        }
    }
}

/// 메뉴바 아이콘 선택 — 내장 5종 썸네일 또는 커스텀 이미지 파일.
private struct IconPickerRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "menubar.rectangle")
                    .foregroundStyle(MenuBarContentView.accent)
                    .frame(width: 16)
                Text("메뉴바 아이콘")
                    .font(.amonSection)
            }
            HStack(spacing: 8) {
                ForEach(0..<AppIcons.iconCount, id: \.self) { i in
                    let selected = settings.iconIndex == i && !settings.useCustomIcon
                    Button {
                        settings.iconIndex = i
                        settings.useCustomIcon = false
                    } label: {
                        Group {
                            if let img = AppIcons.rawImage(icon: i, stage: 0) {
                                // 아이콘 원본이 흰색 선화(투명 배경)라 라이트 모드에선
                                // 보이지 않는다 — 어두운 타일 위에 올려 항상 또렷하게.
                                Image(nsImage: img)
                                    .resizable()
                                    .padding(5)
                                    .background(Color(red: 0.16, green: 0.16, blue: 0.18))
                            } else {
                                Color.gray
                            }
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    selected
                                        ? MenuBarContentView.accent
                                        : Color(nsColor: .separatorColor),
                                    lineWidth: selected ? 2 : 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help(AppIcons.names[i])
                }

                CustomIconTile()
            }
            Text("마지막 타일로 이미지 파일(PNG 권장, 투명 배경이 자연스러움)을 골라 메뉴바 아이콘으로 쓸 수 있습니다. 내장 아이콘을 누르면 되돌아갑니다.")
                .font(.amonCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 커스텀 아이콘 타일 — 클릭 시 파일 선택, 선택된 이미지는 앱 지원 폴더로 복사해
/// 원본 이동/삭제와 무관하게 유지한다.
private struct CustomIconTile: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button {
            pickCustomIcon()
        } label: {
            Group {
                if let img = AppIcons.customRawImage(path: settings.customIconPath) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        settings.useCustomIcon
                            ? MenuBarContentView.accent
                            : Color(nsColor: .separatorColor),
                        lineWidth: settings.useCustomIcon ? 2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .help("커스텀 아이콘 파일 선택 (PNG/JPEG/TIFF/HEIC)")
    }

    private func pickCustomIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 앱 지원 폴더로 복사 — 원본이 이동/삭제돼도 아이콘이 유지되게.
        let fm = FileManager.default
        do {
            let dir = try fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("A-mon", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("menubar-icon." + url.pathExtension)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            settings.customIconPath = dest.path
        } catch {
            settings.customIconPath = url.path  // 복사 실패 시 원본 경로 그대로 사용
        }
        settings.useCustomIcon = true
    }
}

/// 설정 행 공통 레이아웃 — 제목·설명은 왼쪽 열, 작은 토글은 오른쪽 열에 고정한다.
/// 설명의 오른쪽 끝이 토글 아래로 침범하지 않도록 두 열을 같은 HStack 안에서 배치한다.
private struct CompactSettingToggleRow: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(MenuBarContentView.accent)
                        .frame(width: 16)
                    Text(title)
                        .font(.amonSection)
                }
                Text(description)
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 1)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// 새 버전 자동 설치 토글 — 10분 주기 체크가 상위 버전을 찾으면 즉시 교체·재시작.
private struct AutoUpdateRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        CompactSettingToggleRow(
            icon: "arrow.down.circle",
            title: "새 버전 자동 설치",
            description: "10분마다 서버 릴리즈 채널을 확인해 새 버전이 있으면 자동으로 내려받아(SHA256 검증) 교체 후 재시작합니다. 끄면 메뉴에 설치 항목만 표시됩니다.",
            isOn: $settings.autoUpdateEnabled
        )
    }
}

/// 쿼터 한도 임박 알림 토글 — 잔여 10% 미만이면 macOS 알림.
private struct QuotaAlertsRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        CompactSettingToggleRow(
            icon: "bell.badge",
            title: "쿼터 한도 알림",
            description: "세션/주간 등 잔여 한도가 10% 미만이 되면 macOS 알림을 보냅니다. 창이 리셋되면 다시 알립니다.",
            isOn: $settings.quotaAlertsEnabled
        )
    }
}

/// Claude Code 라이브 세션·서브에이전트 로컬 표시 토글 + 훅 재설치 버튼.
private struct LiveActivityRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CompactSettingToggleRow(
                icon: "dot.radiowaves.left.and.right",
                title: "라이브 세션 표시",
                description: "Claude Code 세션과 실행 중인 서브에이전트를 이 Mac의 A-mon 화면에 표시합니다. 데이터는 서버로 전송하지 않습니다.",
                isOn: enabledBinding
            )

            if settings.liveActivityEnabled {
                HStack(spacing: 8) {
                    Button {
                        state.reinstallLiveHooks()
                    } label: {
                        Label("지금 설정 적용", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)

                    statusView
                    Spacer()
                }
                .padding(.top, 2)

                Text("Claude Code 설정(~/.claude/settings.json)이 외부에서 초기화됐다면 이 버튼으로 훅을 다시 설치할 수 있습니다.")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.liveActivityEnabled },
            set: { newValue in
                settings.liveActivityEnabled = newValue
                state.setLiveActivity(enabled: newValue)
            }
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch state.liveOutcome {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("적용 중…").font(.amonCaption).foregroundStyle(.secondary)
            }
        case .success(let date):
            Label(
                "적용됨 \(date.formatted(date: .omitted, time: .shortened))",
                systemImage: "checkmark.circle.fill"
            )
            .font(.amonCaption)
            .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.amonCaption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

/// 메뉴바 아이콘 옆 세션(5h) 쿼터 % 표시 토글 + 표기 방식(사용/남은) 선택.
private struct MenuBarQuotaRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompactSettingToggleRow(
                icon: "percent",
                title: "메뉴바에 세션 쿼터 % 표시",
                description: "기본은 가장 많이 사용한 도구의 5시간(세션) 쿼터 %입니다. 각 그래프 하단의 '상태창 보기' 토글로 위/아래 두 항목을 선택할 수 있습니다. 사용 90% 초과 시 빨간색.",
                isOn: $settings.menuBarQuotaEnabled
            )

            CompactSettingToggleRow(
                icon: "arrow.left.arrow.right",
                title: "남은 %로 표시",
                description: "끄면 사용한 %(기본), 켜면 남은 %(100 − 사용)를 표시합니다.",
                isOn: $settings.menuBarQuotaShowsRemaining,
                enabled: settings.menuBarQuotaEnabled
            )
            .padding(.top, 6)
        }
    }
}

/// "로그인 시 자동 실행" 토글. 상태 출처는 시스템(SMAppService)이다.
private struct LaunchAtLoginRow: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let errorText {
                CompactSettingToggleRow(
                    icon: "power",
                    title: "로그인 시 자동 실행",
                    description: errorText,
                    isOn: binding
                )
            } else {
                CompactSettingToggleRow(
                    icon: "power",
                    title: "로그인 시 자동 실행",
                    description: "켜면 Mac 로그인 시 메뉴바에 자동으로 실행됩니다.",
                    isOn: binding
                )
            }
        }
        .onAppear { enabled = LoginItem.isEnabled }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    enabled = newValue
                    errorText = nil
                } catch {
                    errorText = error.localizedDescription
                    enabled = LoginItem.isEnabled
                }
            }
        )
    }
}

/// 서버 연동 — 앱 업데이트 확인에 사용하는 서버 URL.
private struct ServerSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 카테고리 헤더('서버 연동 설정')는 SettingsView 가 그린다.
            Text("서버 URL")
                .font(.amonCaption)
                .foregroundStyle(.secondary)
            TextField("https://monitor.example.com", text: $settings.serverURL)
                .textFieldStyle(.roundedBorder)
                .font(.amonMono)
                .lineLimit(1)

            Text("이 주소는 앱 업데이트 확인과 다운로드에만 사용됩니다. 사용량과 세션 데이터는 서버로 전송하지 않습니다.")
                .font(.amonCaption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 한 도구의 경로 입력란 + 폴더 선택 + 기본값 리셋.
private struct PathEditor: View {
    let tool: AITool
    @EnvironmentObject private var settings: AppSettings

    private var exists: Bool {
        let path = settings.path(for: tool)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tool.iconName)
                    .foregroundStyle(tool.tint)
                    .frame(width: 16)
                Text(tool.displayName)
                    .font(.amonSection)
                Spacer()
                // 경로 존재 여부 표시
                Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.amonBody)
                    .foregroundStyle(exists ? .green : .orange)
                    .help(exists ? "경로 확인됨" : "경로를 찾을 수 없음")
            }

            HStack(spacing: 6) {
                TextField("", text: settings.binding(for: tool))
                    .textFieldStyle(.roundedBorder)
                    .font(.amonMono)
                    .lineLimit(1)

                Button {
                    chooseFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("폴더 선택")

                Button {
                    settings.reset(tool)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .help("기본값으로 되돌리기")
            }

            Text(tool.pathHint)
                .font(.amonCaption)
                .foregroundStyle(.tertiary)
        }
    }

    /// NSOpenPanel 로 폴더(또는 파일)를 선택한다.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true // OpenCode 는 .db 파일을 가리킬 수도 있음
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "선택"
        let current = settings.path(for: tool)
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        // 메뉴바 앱(accessory)은 패널이 뒤로 가지 않도록 활성화.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.binding(for: tool).wrappedValue = url.path
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(AppSettings())
        .frame(width: 420, height: 420)
}
