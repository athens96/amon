import SwiftUI

/// 세션 상세에서 넘어오는 **정적 분석** 화면 — ① 위험 신호 ② 쉘 요청
/// ③ 파일 읽기/쓰기. 원본 로그는 이 화면을 열 때 한 번, 오프메인에서 읽는다
/// (`SessionAuditLoader`). AI 호출 없음 — 전부 로컬 규칙 매칭이다.
struct SessionAuditView: View {
    let record: SessionRecord
    let onBack: () -> Void

    @EnvironmentObject private var settings: AppSettings

    @State private var audit: SessionAudit?
    @State private var failure: String?
    @State private var isLoading = true
    /// 접힌 상태에서 전체가 안 보이는 항목(위험 신호·쉘·파일)을 탭으로 펼친다.
    /// 항목 id 를 담는다 — 들어 있으면 전체 표시, 없으면 요약(줄 수 제한).
    @State private var expanded: Set<String> = []

    private func isExpanded(_ id: String) -> Bool { expanded.contains(id) }
    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: record.id) { await load() }
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MenuBarContentView.accent)
                    ProviderMark(provider: record.provider)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("세션 분석")
                            .font(.amonBody.weight(.semibold))
                        Text(record.projectLabel.isEmpty ? "(프로젝트 미상)" : record.projectLabel)
                            .font(.amonCaption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("대화 상세로 돌아가기")
            Spacer()
            if let audit {
                Text("쉘 \(audit.shellCommands.count) · 파일 \(audit.fileAccesses.count) · 신호 \(audit.findings.count)")
                    .font(.amonCaption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centered {
                ProgressView().controlSize(.small)
                Text("원본 로그를 분석하는 중…")
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
            }
        } else if let failure {
            centered {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(failure).font(.amonBody.weight(.semibold))
                Text("로그가 정리됐거나 다른 기기에서 만든 세션일 수 있습니다.")
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
            }
        } else if let audit {
            if audit.isEmpty {
                centered {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("분석할 툴 호출이 없습니다").font(.amonBody.weight(.semibold))
                    Text("쉘/파일 툴을 쓰지 않은 대화 전용 세션입니다.")
                        .font(.amonCaption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        findingsSection(audit)
                        skillsSection(audit)
                        summarySection(audit)
                        shellSection(audit)
                        filesSection(audit)
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - ① 위험 신호

    @ViewBuilder
    private func findingsSection(_ audit: SessionAudit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                icon: "shield.lefthalf.filled",
                title: "위험 신호",
                count: audit.findings.count
            )
            if audit.findings.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("정적 규칙에 걸린 행동이 없습니다")
                        .font(.amonCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(audit.findings) { finding in
                        findingRow(finding)
                    }
                }
            }
        }
    }

    private func findingRow(_ finding: SessionAudit.Finding) -> some View {
        let critical = finding.severity == .critical
        let color: Color = critical ? .red : .orange
        let open = isExpanded(finding.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(finding.title)
                    .font(.amonCaption.weight(.semibold))
                Text(critical ? "위험" : "주의")
                    .font(.amonCaption)
                    .foregroundStyle(color)
                Spacer(minLength: 4)
                expandChevron(open)
            }
            Text(finding.evidence)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(open ? nil : 2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { toggle(finding.id) }
        .help(open ? "접기" : "전체 보기")
    }

    /// 접힘/펼침 힌트 아이콘 — 행 오른쪽 위.
    private func expandChevron(_ open: Bool) -> some View {
        Image(systemName: open ? "chevron.up" : "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    // MARK: - 스킬 · 플러그인(MCP)

    @ViewBuilder
    private func skillsSection(_ audit: SessionAudit) -> some View {
        if !audit.skills.isEmpty || !audit.plugins.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(icon: "puzzlepiece.extension", title: "스킬 · 플러그인", count: nil)
                if !audit.skills.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        summaryLabel("사용된 스킬")
                        chipFlow(audit.skills, tint: MenuBarContentView.accent)
                    }
                }
                if !audit.plugins.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        summaryLabel("플러그인 · MCP")
                        chipFlow(audit.plugins, tint: .secondary)
                    }
                }
            }
        }
    }

    /// 이름×횟수 칩 목록 — 좁은 팝오버에서 자동 줄바꿈.
    private func chipFlow(_ items: [SessionAudit.NamedCount], tint: Color) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(items) { item in
                HStack(spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                    if item.count > 1 {
                        Text("×\(item.count)")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint.opacity(0.12))
                .clipShape(Capsule())
                .textSelection(.enabled)
            }
        }
    }

    // MARK: - 사용 빈도 요약 (많이 쓴 커맨드 · 많이 읽은/쓴 파일)

    private static let topCommandLimit = 10
    private static let topFileLimit = 5

    @ViewBuilder
    private func summarySection(_ audit: SessionAudit) -> some View {
        let commands = Array(audit.commandCounts.prefix(Self.topCommandLimit))
        let reads = Array(audit.topReadFiles.prefix(Self.topFileLimit))
        let writes = Array(audit.topWrittenFiles.prefix(Self.topFileLimit))
        if !commands.isEmpty || !reads.isEmpty || !writes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(icon: "chart.bar", title: "사용 빈도", count: nil)
                if !commands.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        summaryLabel("많이 사용된 커맨드")
                        Text(commands.map { "\($0.name) ×\($0.count)" }.joined(separator: "  ·  "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                if !reads.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        summaryLabel("많이 읽은 파일")
                        ForEach(reads) { access in
                            topFileRow(access, count: access.reads, label: "읽기", tint: .secondary)
                        }
                    }
                }
                if !writes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        summaryLabel("많이 쓴 파일")
                        ForEach(writes) { access in
                            topFileRow(
                                access, count: access.writes, label: "쓰기",
                                tint: MenuBarContentView.accent
                            )
                        }
                    }
                }
            }
        }
    }

    private func summaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.amonCaption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func topFileRow(
        _ access: SessionAudit.FileAccess, count: Int, label: String, tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Text(access.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(access.path)
            accessBadge("\(label) \(count)", tint: tint)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - ② 쉘 요청

    @ViewBuilder
    private func shellSection(_ audit: SessionAudit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(icon: "terminal", title: "쉘 요청", count: audit.shellCommands.count)
            if audit.shellCommands.isEmpty {
                emptyLine("쉘 명령 실행이 없습니다")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(audit.shellCommands) { shell in
                        let key = "shell-\(shell.id)"
                        let open = isExpanded(key)
                        HStack(alignment: .top, spacing: 6) {
                            if let time = timeString(shell.timestamp) {
                                Text(time)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 1)
                            }
                            if shell.fromSubagent {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                    .help("서브에이전트가 실행")
                                    .padding(.top, 2)
                            }
                            Text(shell.command)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(open ? nil : 3)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if isMultiline(shell.command) {
                                expandChevron(open).padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(key) }
                    }
                }
            }
        }
    }

    // MARK: - ③ 파일 읽기/쓰기

    @ViewBuilder
    private func filesSection(_ audit: SessionAudit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                icon: "doc.text", title: "파일 읽기/쓰기", count: audit.fileAccesses.count
            )
            if audit.fileAccesses.isEmpty {
                emptyLine("파일 툴 호출이 없습니다 (쉘 명령 안의 파일 접근은 위 목록 참조)")
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(audit.fileAccesses) { access in
                        let key = "file-\(access.path)"
                        let open = isExpanded(key)
                        HStack(spacing: 6) {
                            Text(access.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(open ? nil : 1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if access.reads > 0 {
                                accessBadge("읽기 \(access.reads)", tint: .secondary)
                            }
                            if access.writes > 0 {
                                accessBadge("쓰기 \(access.writes)", tint: MenuBarContentView.accent)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(key) }
                        .help(open ? "접기" : access.path)
                    }
                }
            }
        }
    }

    // MARK: - 공용 조각

    private func sectionHeader(icon: String, title: String, count: Int?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(title)
            if let count {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 0.5)
        }
        .font(.amonCaption)
        .foregroundStyle(.tertiary)
    }

    private func accessBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.amonCaption)
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.1))
            .clipShape(Capsule())
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.amonCaption)
            .foregroundStyle(.tertiary)
    }

    /// 3줄 넘어가거나 줄바꿈이 있으면 펼침 대상 — 짧은 한 줄엔 chevron 을 숨긴다.
    private func isMultiline(_ text: String) -> Bool {
        text.contains("\n") || text.count > 120
    }

    private func timeString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func centered<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        VStack(spacing: 8) {
            Spacer()
            body()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        isLoading = true
        failure = nil
        let record = record
        let claudeRoot = settings.claudePath
        let codexRoot = settings.codexPath
        let cursorRoot = settings.cursorPath

        let result = await Task.detached(priority: .userInitiated) { () -> Result<SessionAudit, Error> in
            do {
                return .success(
                    try SessionAuditLoader.load(
                        record, claudeRoot: claudeRoot, codexRoot: codexRoot,
                        cursorRoot: cursorRoot
                    )
                )
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let loaded):
            audit = loaded
        case .failure(let error):
            failure = (error as? TranscriptError)?.errorDescription
                ?? "원본 로그를 읽지 못했습니다"
        }
        isLoading = false
    }
}

/// 좁은 팝오버에서 칩(스킬·플러그인 배지)을 좌→우로 채우고 넘치면 다음 줄로
/// 흘리는 단순 flow 레이아웃. 가용 폭 기준으로만 배치한다(Layout, macOS 13+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
