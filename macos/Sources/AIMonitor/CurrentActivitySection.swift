import SwiftUI

/// "현재 활동" 섹션 — `DashboardView` 안에 임베드되는 컴포넌트 (독립 탭이 아니다).
/// 전체 보기에서는 사용량 히어로 카드 바로 아래에 붙는다. Claude Code 는 훅 상태,
/// Codex CLI 는 rollout 로그의 최근 갱신 상태를 보여준다.
///
/// 이 기기에서 지금 살아있는 AI 도구 세션(어느 레포·브랜치)과, Claude 의 경우
/// 실행 중인 서브에이전트(어떤 에이전트로 어떤 지시를 진행 중인지 1줄 요약)를 보여준다.
struct CurrentActivitySection: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    /// 세션 행 클릭 → 상세(지금까지의 전체 대화) 열기. 세션 기록 화면과 같은
    /// `SessionTranscriptView` 를 재사용한다. nil 이면 행이 클릭되지 않는다.
    var onOpenSession: ((SessionRecord) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader
            content
        }
        .padding(.top, 2)
    }

    private var sectionHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 10))
            Text("현재 활동")
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 0.5)
        }
        .font(.amonCaption)
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var content: some View {
        if !settings.localActivityEnabled {
            disabledRow
        } else if state.liveActivity.sessions.isEmpty {
            Text("지금 이 기기에서 실행 중인 AI 도구 세션이 없습니다")
                .font(.amonCaption)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.liveActivity.sessions, id: \.identity) { session in
                    sessionRow(session)
                }
            }
        }
    }

    /// 트랜스크립트를 열 수 있는 세션이면 행 전체를 클릭 대상으로 만든다
    /// (claude·codex 는 로그, cursor 는 전역 state.vscdb 에서 복원).
    @ViewBuilder
    private func sessionRow(_ session: LiveSession) -> some View {
        if let onOpenSession,
           ["claude", "codex", "cursor"].contains(session.provider) {
            Button {
                onOpenSession(record(for: session))
            } label: {
                SessionRow(session: session, clickable: true)
            }
            .buttonStyle(.plain)
            .help("클릭하면 지금까지의 요청·응답 전체를 봅니다")
        } else {
            SessionRow(session: session)
        }
    }

    /// 상세 화면에 넘길 레코드 — 같은 세션의 기록(스캔 결과)이 이미 있으면 그걸
    /// 쓰고(원본 로그 경로·토큰 분해가 실려 있다), 없으면(진행 중이라 아직 미적재)
    /// 라이브 상태로 합성한다. 원본 로그는 어차피 상세가 세션 id 로 찾아 읽는다.
    private func record(for session: LiveSession) -> SessionRecord {
        if let existing = state.sessionHistory.records.first(where: { $0.id == session.identity }) {
            return existing
        }
        return SessionRecord(
            provider: session.provider,
            sessionId: session.sessionId,
            projectLabel: session.projectLabel,
            gitBranch: session.gitBranch,
            startedAt: session.startedAt,
            endedAt: session.updatedAt,
            prompts: session.currentTask.map { [$0] } ?? [],
            promptCount: session.currentTask == nil ? 0 : 1,
            currentTask: session.currentTask,
            lastResult: session.lastResult,
            inputTokens: 0,
            outputTokens: 0,
            cacheTokens: 0,
            totalTokens: session.totalTokens ?? 0,
            models: session.model.map { [$0: session.totalTokens ?? 0] } ?? [:],
            agentCount: session.agents.count,
            sourcePath: nil
        )
    }

    /// 꺼져 있을 때 — 누르면 바로 켠다(설정 화면으로 안 보내고 그 자리에서 처리).
    private var disabledRow: some View {
        Button {
            settings.localActivityEnabled = true
            state.setLiveActivity(enabled: true)
        } label: {
            HStack(spacing: 4) {
                Text("이 기기의 현재 활동 표시가 꺼져 있습니다")
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                Text("· 지금 켜기")
                    .font(.amonCaption.weight(.semibold))
                    .foregroundStyle(MenuBarContentView.accent)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SessionRow: View {
    let session: LiveSession
    /// 행이 클릭 대상일 때 true — hover 하이라이트 + 우측 chevron 을 보여준다.
    var clickable: Bool = false

    @State private var hovering = false

    private var isActive: Bool { session.status == "active" }

    private var label: String {
        if let branch = session.gitBranch, !branch.isEmpty {
            return "\(session.projectLabel) · \(branch)"
        }
        return session.projectLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderMark(provider: session.provider)
                Text(label)
                    .font(.amonBody.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                statusBadge
                if clickable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Color.secondary : Color.secondary.opacity(0.35))
                }
            }
            Text("\(RelativeTime.string(from: session.startedAt)) 시작")
                .font(.amonCaption)
                .foregroundStyle(.tertiary)

            if !sessionMeta.isEmpty {
                Text(sessionMeta)
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let task = session.currentTask, !task.isEmpty {
                Text("\(isActive ? "지금" : "최근"): \(task)")
                    .font(.amonCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // 턴이 끝난 뒤에만 응답 요약을 보여준다(작업 중엔 직전 응답이 헷갈린다).
            if !isActive, let result = session.lastResult, !result.isEmpty {
                Text("↳ \(result)")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(result)
            }

            if !session.agents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.agents, id: \.toolUseId) { agent in
                        AgentRow(agent: agent)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(clickable && hovering ? 0.07 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? MenuBarContentView.accent : Color.secondary)
                .frame(width: 6, height: 6)
            Text(isActive ? "작업 중" : "대기")
                .font(.amonCaption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(isActive ? MenuBarContentView.accent.opacity(0.15) : Color.secondary.opacity(0.12))
        .foregroundStyle(isActive ? MenuBarContentView.accent : .secondary)
        .clipShape(Capsule())
    }

    private var sessionMeta: String {
        [
            session.model,
            session.totalTokens.map { "\($0.formatted()) tokens" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

struct AgentRow: View {
    let agent: LiveAgent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(MenuBarContentView.accent)
            Text(agent.agentType)
                .font(.amonCaption.weight(.semibold))
                .fixedSize()
            Text(agent.description)
                .font(.amonCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// 프로바이더 공식 로고(없으면 SF Symbol 폴백) — 라이브·기록 화면 공용.
/// 세션 목록엔 Claude Code·Codex 가 섞이므로 한눈에 구분되게 한다.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let logo = ProviderIcons.swiftUIImage(id: provider) {
                logo.resizable().scaledToFit()
            } else {
                Image(systemName: "terminal").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(MenuBarContentView.accent)
        .help(provider)
    }
}

/// 상대 시각 문자열 ("3분 전" 등) — Foundation `RelativeDateTimeFormatter` 래퍼.
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .short
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    CurrentActivitySection()
        .environmentObject(AppState())
        .environmentObject(AppSettings())
        .padding()
        .frame(width: 400)
}
