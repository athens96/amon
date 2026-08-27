import Foundation

/// Codex Pet 과 의미를 맞춘 활동 상태.
///
/// `idle` 은 활동이 없을 때 사용하는 amon 확장 상태다. 나머지 네 상태의
/// 대표 활동 우선순위는 Codex Pet 과 동일하게
/// Needs Input > Blocked > Ready > Running 순서다.
enum PetActivityStatus: String, Codable, CaseIterable {
    case idle
    case running
    /// 결과를 검토·검증하는 중 — Codex Pet 의 review 행에 대응한다.
    case reviewing
    case needsInput
    case ready
    case blocked

    /// 지금 손이 움직이고 있는 상태 — 캐러셀의 1/N 은 이 상태들만 센다.
    var isWorking: Bool {
        self == .running || self == .reviewing
    }

    fileprivate var presentationPriority: Int {
        switch self {
        case .idle: 0
        case .running: 1
        case .reviewing: 2
        case .ready: 3
        case .blocked: 4
        case .needsInput: 5
        }
    }
}

/// 펫 오버레이가 표시할 단일 대표 활동.
///
/// 로컬에서 이미 축약된 `LiveSession` 정보만 담는다. 원문 프롬프트나 응답,
/// 트랜스크립트 및 업로드 기능은 이 모델의 책임이 아니다.
struct PetPresentation: Equatable {
    let status: PetActivityStatus
    let title: String
    /// 최근 사용자 입력 첫 줄.
    let detail: String?
    /// 최근 assistant 출력 첫 줄.
    let output: String?
    let provider: String?
    let sessionID: String?
    /// provider를 포함한 안정적인 캐러셀 식별자.
    let sessionIdentity: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let updatedAt: Date?
    /// 현재 작동 중이거나 명시적인 lifecycle 상태를 가진 활동 수.
    let activeCount: Int
    /// 로컬 세션 호스트 이동과 턴 히스토리에만 쓰는 메타데이터.
    let hostApp: String?
    let hostPID: Int?
    let cwd: String?
    let transcriptPath: String?

    static let idle = PetPresentation(
        status: .idle,
        title: "amon",
        detail: nil,
        output: nil,
        provider: nil,
        sessionID: nil,
        sessionIdentity: nil,
        inputTokens: nil,
        outputTokens: nil,
        totalTokens: nil,
        updatedAt: nil,
        activeCount: 0,
        hostApp: nil,
        hostPID: nil,
        cwd: nil,
        transcriptPath: nil
    )
}

/// App Server 등 더 정확한 lifecycle 이벤트가 생겼을 때 `LiveSession`을
/// 변경하지 않고 Pet 상태를 보강하는 값.
///
/// 딕셔너리 키는 `LiveSession.identity` 를 사용한다.
struct PetActivityOverride: Equatable {
    var status: PetActivityStatus?
    var title: String?
    var detail: String?

    init(
        status: PetActivityStatus? = nil,
        title: String? = nil,
        detail: String? = nil
    ) {
        self.status = status
        self.title = title
        self.detail = detail
    }
}

/// 여러 로컬 세션을 Codex Pet 우선순위에 따라 하나의 표시 상태로 축약한다.
enum PetStateAdapter {
    static func presentation(for sessions: [LiveSession]) -> PetPresentation {
        presentations(for: sessions, overrides: [:]).first ?? .idle
    }

    /// 사용자가 로컬 활동 감지를 끈 경우 메모리에 남은 직전 세션도 표시하지 않는다.
    static func presentation(
        for sessions: [LiveSession],
        localActivityEnabled: Bool
    ) -> PetPresentation {
        guard localActivityEnabled else { return .idle }
        return presentation(for: sessions)
    }

    static func presentation(
        for sessions: [LiveSession],
        overrides: [String: PetActivityOverride]
    ) -> PetPresentation {
        presentations(for: sessions, overrides: overrides).first ?? .idle
    }

    static func presentations(
        for sessions: [LiveSession],
        localActivityEnabled: Bool
    ) -> [PetPresentation] {
        guard localActivityEnabled else { return [] }
        return presentations(for: sessions, overrides: [:])
    }

    static func presentations(
        for sessions: [LiveSession],
        overrides: [String: PetActivityOverride]
    ) -> [PetPresentation] {
        guard !sessions.isEmpty else { return [] }

        let candidates = sessions.map { session -> Candidate in
            let override = overrides[session.identity]
            let status = override?.status ?? status(from: session.status)
            // 입력을 기다리는 중이면 "무엇을 기다리는지"(권한 승인 등)가 지금 할 일보다
            // 중요하다. 그 외 상태에서는 notice 가 비어 있어 평소와 동일하게 동작한다.
            let waitReason = status == .needsInput
                ? normalizedLine(session.notice, limit: 120)
                : nil
            return Candidate(
                session: session,
                status: status,
                title: normalizedLine(override?.title, limit: 80)
                    ?? normalizedLine(session.projectLabel, limit: 80)
                    ?? providerTitle(session.provider),
                detail: normalizedLine(override?.detail, limit: 120)
                    ?? waitReason
                    ?? normalizedLine(session.currentTask, limit: 120)
            )
        }

        // 승인 요청·차단은 놓치면 안 되는 단일 알림으로 우선 표시하되,
        // 실행 중 세션 캐러셀의 1/N 개수에는 섞지 않는다.
        let attention = candidates
            .filter { $0.status == .needsInput || $0.status == .blocked }
            .sorted(by: isHigherPriority)
        if let firstAttention = attention.first {
            return [makePresentation(from: firstAttention, activeCount: 1)]
        }

        // 1/N은 오직 지금 작동 중인 세션들만 의미한다.
        let running = candidates
            .filter { $0.status.isWorking }
            .sorted(by: isHigherPriority)
        if !running.isEmpty {
            return running.map {
                makePresentation(from: $0, activeCount: running.count)
            }
        }

        // 실행 중 세션이 없을 때만 가장 최근 완료 결과 하나를 단독 표시한다.
        // 과거 idle 세션 여러 개가 1/N 캐러셀로 보이는 것을 방지한다.
        let latestCompleted = candidates
            .filter {
                guard let result = $0.session.lastResult?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) else { return false }
                return !result.isEmpty
            }
            .max(by: {
                if $0.session.updatedAt != $1.session.updatedAt {
                    return $0.session.updatedAt < $1.session.updatedAt
                }
                return $0.session.identity > $1.session.identity
            })
        guard let latestCompleted else {
            return []
        }
        let fallback = Candidate(
            session: latestCompleted.session,
            status: .ready,
            title: latestCompleted.title,
            detail: latestCompleted.detail
        )
        return [makePresentation(from: fallback, activeCount: 0)]
    }

    /// 현재 파서의 `active`/`idle`을 보존하면서 미래 lifecycle 문자열도
    /// 보수적으로 해석한다. 모르는 값은 작업 중으로 오인하지 않고 idle 로 둔다.
    static func status(from rawStatus: String) -> PetActivityStatus {
        let normalized = rawStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "needs_input", "input_required", "awaiting_input", "waiting_for_input",
             "awaiting_approval", "requires_approval", "requires_action":
            return .needsInput
        case "blocked", "error", "failed", "failure":
            return .blocked
        case "ready", "complete", "completed", "done", "success", "succeeded":
            return .ready
        case "review", "reviewing", "in_review", "verify", "verifying", "checking":
            return .reviewing
        case "active", "running", "working", "in_progress", "busy":
            return .running
        case "idle", "inactive", "paused", "waiting":
            return .idle
        default:
            return .idle
        }
    }

    private static func makePresentation(
        from selected: Candidate,
        activeCount: Int
    ) -> PetPresentation {
        PetPresentation(
            status: selected.status,
            title: selected.title,
            detail: selected.detail,
            // 훅이 저장하는 응답 첫 줄 상한(200자)까지 그대로 넘긴다 —
            // 말풍선을 키우면 잘리지 않고 더 보인다.
            output: normalizedLine(selected.session.lastResult, limit: 200),
            provider: selected.session.provider,
            sessionID: selected.session.sessionId,
            sessionIdentity: selected.session.identity,
            inputTokens: selected.session.inputTokens,
            outputTokens: selected.session.outputTokens,
            totalTokens: selected.session.totalTokens,
            updatedAt: selected.session.updatedAt,
            activeCount: activeCount,
            hostApp: selected.session.hostApp,
            hostPID: selected.session.hostPID,
            cwd: selected.session.cwd,
            transcriptPath: selected.session.transcriptPath
        )
    }

    private struct Candidate {
        let session: LiveSession
        let status: PetActivityStatus
        let title: String
        let detail: String?
    }

    private static func isHigherPriority(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.status.presentationPriority != rhs.status.presentationPriority {
            return lhs.status.presentationPriority > rhs.status.presentationPriority
        }
        // 캐러셀 순서가 5초 폴링마다 흔들리지 않도록 세션 시작 시각을 사용한다.
        if lhs.session.startedAt != rhs.session.startedAt {
            return lhs.session.startedAt > rhs.session.startedAt
        }
        return lhs.session.identity < rhs.session.identity
    }

    private static func normalizedLine(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        ).first.map(String.init) ?? ""
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }

    private static func providerTitle(_ provider: String) -> String {
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "amon" }
        return normalized.prefix(1).uppercased() + normalized.dropFirst()
    }
}

/// 말풍선을 펼칠지 접을지 정하는 순수 판정.
///
/// 완료는 "다 됐다"는 알림 성격이라 잠깐 보여준 뒤 접는다. 입력 필요·문제 발생은
/// 사람이 손을 대야 하는 상태이므로 시간이 지나도 그대로 둔다.
enum PetBubbleVisibility {
    /// 완료 상태를 보여주는 기본 시간. 설정에서 바꿀 수 있다.
    static let defaultReadyAutoHideDelay: TimeInterval = 30

    /// 설정에서 고를 수 있는 값들 — 0 은 "숨기지 않음".
    static let readyAutoHideChoices: [TimeInterval] = [0, 10, 15, 30, 60, 120, 300]

    static func showsBubble(
        presentation: PetPresentation,
        showsCurrentTask: Bool,
        localActivityEnabled: Bool,
        now: Date,
        readyAutoHideDelay: TimeInterval = defaultReadyAutoHideDelay
    ) -> Bool {
        guard showsCurrentTask else { return false }
        // 감지가 꺼져 있으면 상태 대신 안내 문구를 띄운다.
        guard localActivityEnabled else { return true }

        switch presentation.status {
        case .idle:
            return false
        case .ready:
            // 0 이하면 자동으로 접지 않는다.
            guard readyAutoHideDelay > 0 else { return true }
            guard let updatedAt = presentation.updatedAt else { return true }
            return now.timeIntervalSince(updatedAt) < readyAutoHideDelay
        case .running, .reviewing, .needsInput, .blocked:
            return true
        }
    }

    /// 설정 UI 에 쓰는 사람이 읽는 라벨.
    static func autoHideLabel(forSeconds seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "숨기지 않음" }
        guard seconds >= 60 else { return "\(Int(seconds))초" }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.truncatingRemainder(dividingBy: 60))
        return remainder == 0 ? "\(minutes)분" : "\(minutes)분 \(remainder)초"
    }
}

/// 단일 말풍선에서 여러 라이브 세션을 순환할 때 사용하는 순수 선택 로직.
/// 말풍선이 놓인 "상황" — 이 값이 바뀌면 사용자의 수동 여닫기를 되돌린다.
struct PetBubbleContext: Equatable {
    let status: PetActivityStatus
    let sessionIdentity: String?

    init(status: PetActivityStatus, sessionIdentity: String?) {
        self.status = status
        self.sessionIdentity = sessionIdentity
    }

    init(_ presentation: PetPresentation) {
        self.init(
            status: presentation.status,
            sessionIdentity: presentation.sessionIdentity
        )
    }
}

/// 펫을 눌러 말풍선을 강제로 여닫은 상태.
///
/// 수동 결정은 "지금 이 상황"에만 적용한다. 상태가 바뀌거나 다른 세션이 대표가 되면
/// 자동 판정으로 돌아가야, 접어둔 말풍선 때문에 다음 작업을 놓치지 않는다.
struct PetBubbleOverride: Equatable {
    private(set) var manualShows: Bool?
    private(set) var context: PetBubbleContext?

    /// 지금 보이는 상태의 반대로 뒤집는다.
    mutating func toggle(currentlyShowing: Bool) {
        manualShows = !currentlyShowing
    }

    /// 상황이 바뀌었으면 수동 결정을 버린다.
    mutating func sync(context newContext: PetBubbleContext) {
        guard context != newContext else { return }
        context = newContext
        manualShows = nil
    }

    /// 수동 결정이 있으면 그것을, 없으면 자동 판정을 따른다.
    func resolve(auto: Bool) -> Bool {
        manualShows ?? auto
    }
}

enum PetCarousel {
    static func index(
        selectedIdentity: String?,
        in presentations: [PetPresentation]
    ) -> Int {
        guard let selectedIdentity,
              let index = presentations.firstIndex(
                where: { $0.sessionIdentity == selectedIdentity }
              )
        else {
            return 0
        }
        return index
    }

    static func movedIdentity(
        selectedIdentity: String?,
        offset: Int,
        in presentations: [PetPresentation]
    ) -> String? {
        guard !presentations.isEmpty else { return nil }
        let current = index(
            selectedIdentity: selectedIdentity,
            in: presentations
        )
        let count = presentations.count
        let next = (current + offset % count + count) % count
        return presentations[next].sessionIdentity
    }

    static func preservedIdentity(
        selectedIdentity: String?,
        previousIndex: Int,
        in presentations: [PetPresentation]
    ) -> String? {
        guard !presentations.isEmpty else { return nil }
        if let selectedIdentity,
           presentations.contains(where: {
               $0.sessionIdentity == selectedIdentity
           }) {
            return selectedIdentity
        }
        return presentations[min(max(previousIndex, 0), presentations.count - 1)]
            .sessionIdentity
    }
}
