import AppKit
import SwiftUI

/// 세션 기록에서 한 건을 클릭했을 때 목록 자리에 뜨는 상세 — 요청·응답 **전체**를
/// 최신순(최근 요청→응답 페어가 위)으로 보여 준다. 페어 내부는 항상 요청→응답
/// 순서. 헤더의 점프 버튼으로 맨 위(최근)/맨 아래(처음)로 이동한다.
///
/// 목록은 요약(첫 줄)만 들고 있으므로 여기서 원본 로그를 읽는다. 읽기는 화면이
/// 열릴 때 한 번, 오프메인에서만 한다(`SessionTranscriptLoader`).
struct SessionTranscriptView: View {
    let record: SessionRecord
    /// 진행 중(라이브) 세션 여부 — "현재 활동" 에서 열었을 때 true. 헤더 문구가
    /// "종료" 대신 "진행 중" 이 되고, 새 턴을 다시 읽는 새로고침 버튼이 생긴다.
    var isLive: Bool = false
    let onBack: () -> Void

    @EnvironmentObject private var settings: AppSettings

    @State private var turns: [TranscriptTurn] = []
    @State private var failure: String?
    @State private var isLoading = true

    /// 스크롤 점프용 앵커 id — 턴 id 와 충돌하지 않는 고정 문자열.
    private static let topAnchor = "transcript-top"
    private static let bottomAnchor = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header(proxy)
                Divider()
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: record.id) { await load() }
    }

    // MARK: - 헤더

    private var title: String {
        if let branch = record.gitBranch, !branch.isEmpty {
            return "\(record.projectLabel) · \(branch)"
        }
        return record.projectLabel.isEmpty ? "(프로젝트 미상)" : record.projectLabel
    }

    private func header(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            // 뒤로가기는 chevron 만이 아니라 제목 블록 전체가 클릭 대상이다 —
            // 팝오버에서 11pt 아이콘만 노리게 하면 미스클릭이 잦다.
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MenuBarContentView.accent)
                    ProviderMark(provider: record.provider)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.amonBody.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(
                            isLive
                                ? "\(RelativeTime.string(from: record.startedAt)) 시작 · 진행 중"
                                : "\(RelativeTime.string(from: record.endedAt)) 종료 · 요청 \(record.promptCount)개"
                        )
                        .font(.amonCaption)
                        .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("세션 목록으로")
            Spacer()
            Text(TokenFormat.compact(record.totalTokens))
                .font(.amonCaption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(MenuBarContentView.accent)
                .help("총 \(TokenFormat.grouped(record.totalTokens)) 토큰")

            if isLive {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("진행 중인 세션 — 새 요청·응답 다시 읽기")
            }

            if let path = resolvedPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("원본 로그를 Finder 에서 보기")
            }

            Button {
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            } label: {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("맨 위로 (최근)")

            Button {
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("맨 아래로 (처음)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 헤더의 Finder 버튼용 — 없으면 버튼을 감춘다.
    private var resolvedPath: String? {
        SessionTranscriptLoader.resolveSource(
            record, claudeRoot: settings.claudePath, codexRoot: settings.codexPath,
            cursorRoot: settings.cursorPath
        )
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centered {
                ProgressView().controlSize(.small)
                Text("원본 로그를 읽는 중…")
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
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // 점프 대상 앵커 — 첫/끝 카드 id 로 스크롤하면 LazyVStack
                    // 미레이아웃 구간에서 어긋날 수 있어 고정 마커를 둔다.
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    ForEach(displayGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.turns) { turn in
                                TranscriptTurnCard(turn: turn)
                            }
                        }
                    }
                    Color.clear.frame(height: 0).id(Self.bottomAnchor)
                }
                .padding(12)
            }
        }
    }

    /// 요청 하나 + 뒤따르는 응답들 = 한 페어. 최신순으로 뒤집어도 페어 안의
    /// 요청→응답 순서는 유지돼야 해서 턴이 아니라 이 묶음 단위로 다룬다.
    private struct TurnGroup: Identifiable {
        let id: Int
        let turns: [TranscriptTurn]
    }

    /// 시간순 페어 목록 — 요청(user) 턴이 새 묶음을 열고, 요청 없이 시작하는
    /// 선행 응답들도 하나의 묶음으로 남긴다.
    private var groups: [TurnGroup] {
        var result: [TurnGroup] = []
        var current: [TranscriptTurn] = []
        for turn in turns {
            if turn.role == .user, !current.isEmpty {
                result.append(TurnGroup(id: current[0].id, turns: current))
                current = []
            }
            current.append(turn)
        }
        if !current.isEmpty {
            result.append(TurnGroup(id: current[0].id, turns: current))
        }
        return result
    }

    /// 최신순 고정 — 최근 요청·응답 페어가 맨 위. 원본 `turns` 는 시간순으로 둔다.
    private var displayGroups: [TurnGroup] {
        groups.reversed()
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

        let result = await Task.detached(priority: .userInitiated) { () -> Result<[TranscriptTurn], Error> in
            do {
                return .success(
                    try SessionTranscriptLoader.load(
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
            turns = loaded
        case .failure(let error):
            failure = (error as? TranscriptError)?.errorDescription
                ?? "원본 로그를 읽지 못했습니다"
        }
        isLoading = false
    }
}

/// 대화 한 턴 — 요청은 강조 배경, 응답은 기본 배경. 본문은 복사할 수 있게 둔다.
private struct TranscriptTurnCard: View {
    let turn: TranscriptTurn

    private var isUser: Bool { turn.role == .user }

    private var time: String? {
        guard let timestamp = turn.timestamp else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: isUser ? "arrow.right" : "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(isUser ? "요청" : "응답")
                    .font(.amonCaption.weight(.semibold))
                Spacer()
                if let time {
                    Text(time)
                        .font(.amonCaption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(isUser ? MenuBarContentView.accent : Color.secondary)

            Text(turn.text)
                .font(.amonCaption)
                .foregroundStyle(isUser ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            isUser
                ? MenuBarContentView.accent.opacity(0.08)
                : Color.primary.opacity(0.04)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
