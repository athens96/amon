import SwiftUI

/// 팝오버 "세션 기록" 탭 — 이 기기에서 종료된 세션들(Claude Code + Codex).
///
/// 라이브 상태(§현재 활동)와 달리 종료된 세션의 **결과**를 본다: 무슨 요청으로
/// 시작해 무슨 응답으로 끝났는지, 몇 토큰을 썼는지, 서브에이전트를 몇 개 돌렸는지.
struct SessionHistoryView: View {
    @EnvironmentObject private var state: AppState

    /// 프로바이더 필터 — nil 이면 전체.
    @State private var providerFilter: String?
    /// 상세(전체 대화)를 보고 있는 세션 — nil 이면 목록.
    @State private var selected: SessionRecord?

    private var providers: [String] {
        Array(Set(state.sessionHistory.records.map(\.provider))).sorted()
    }

    private var visible: [SessionRecord] {
        guard let providerFilter else { return state.sessionHistory.records }
        return state.sessionHistory.records.filter { $0.provider == providerFilter }
    }

    var body: some View {
        Group {
            if let selected {
                // 상세는 목록 자리를 대체한다 — 팝오버라 시트/새 창을 띄우지 않는다.
                SessionTranscriptView(record: selected) { self.selected = nil }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { record in
                            Button { selected = record } label: {
                                SessionHistoryRow(record: record)
                            }
                            .buttonStyle(.plain)
                            .help("클릭하면 요청·응답 전체를 봅니다")
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            filterChip(title: "전체", provider: nil)
            ForEach(providers, id: \.self) { provider in
                filterChip(title: provider, provider: provider)
            }
            Spacer()
            Text("\(visible.count)개")
                .font(.amonCaption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func filterChip(title: String, provider: String?) -> some View {
        let selected = providerFilter == provider
        return Button {
            providerFilter = provider
        } label: {
            HStack(spacing: 4) {
                if let provider { ProviderMark(provider: provider, size: 11) }
                Text(title).font(.amonCaption.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? MenuBarContentView.accent : Color.clear)
                    .frame(height: 2)
            }
            .foregroundStyle(selected ? MenuBarContentView.accent : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("아직 기록된 세션이 없습니다")
                .font(.amonBody.weight(.semibold))
            Text("Claude Code 세션이 끝나거나 Codex 로그가 스캔되면 여기에 쌓입니다.")
                .font(.amonCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

private struct SessionHistoryRow: View {
    let record: SessionRecord
    @State private var hovering = false

    private var label: String {
        if let branch = record.gitBranch, !branch.isEmpty {
            return "\(record.projectLabel) · \(branch)"
        }
        return record.projectLabel.isEmpty ? "(프로젝트 미상)" : record.projectLabel
    }

    /// 세션 길이 — "1시간 23분" 형태.
    private var duration: String {
        let seconds = max(0, record.endedAt.timeIntervalSince(record.startedAt))
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProviderMark(provider: record.provider)
                Text(label)
                    .font(.amonBody.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(TokenFormat.compact(record.totalTokens))
                    .font(.amonCaption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(MenuBarContentView.accent)
                    .help("총 \(TokenFormat.grouped(record.totalTokens)) 토큰")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Color.secondary : Color.secondary.opacity(0.35))
            }

            HStack(spacing: 4) {
                Text("\(RelativeTime.string(from: record.endedAt)) 종료")
                Text("· \(duration)")
                if record.agentCount > 0 {
                    Text("· 에이전트 \(record.agentCount)")
                }
                Spacer()
                if let top = record.models.max(by: { $0.value < $1.value })?.key {
                    Text(ModelBreakdown.shortName(top))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(modelsHelp)
                }
            }
            .font(.amonCaption)
            .foregroundStyle(.tertiary)

            if !record.prompts.isEmpty {
                promptList
            }
            if let result = record.lastResult, !result.isEmpty {
                Text("↳ \(result)")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(result)
            }

            tokenBreakdown
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(hovering ? 0.045 : 0))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// 미리보기 — 요청 첫 2개만. 나머지와 응답 전문은 행을 클릭해 상세에서 본다
    /// (행 전체가 버튼이라 여기에 버튼을 겹쳐 둘 수 없다).
    @ViewBuilder
    private var promptList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(record.prompts.prefix(2).enumerated()), id: \.offset) { _, prompt in
                Text("→ \(prompt)")
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(prompt)
            }
            if record.promptCount > 2 {
                Text("… 총 \(record.promptCount)개 요청")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var modelsHelp: String {
        record.models
            .sorted { $0.value > $1.value }
            .map { "\(ModelBreakdown.shortName($0.key)): \(TokenFormat.compact($0.value))" }
            .joined(separator: "\n")
    }

    private var tokenBreakdown: some View {
        HStack(spacing: 10) {
            tokenCell("입력", record.inputTokens)
            tokenCell("출력", record.outputTokens)
            tokenCell("캐시", record.cacheTokens)
            Spacer()
        }
        .font(.amonCaption)
        .foregroundStyle(.tertiary)
    }

    private func tokenCell(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
            Text(TokenFormat.compact(value))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? Color.secondary : Color.secondary.opacity(0.5))
        }
        .help("\(label) \(TokenFormat.grouped(value)) 토큰")
    }
}

#Preview {
    SessionHistoryView()
        .environmentObject(AppState())
        .frame(width: 440, height: 400)
}
