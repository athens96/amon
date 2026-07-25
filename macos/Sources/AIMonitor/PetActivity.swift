import Foundation

/// Codex Pet 과 의미를 맞춘 활동 상태.
///
/// `idle` 은 활동이 없을 때 사용하는 A-mon 확장 상태다. 나머지 네 상태의
/// 대표 활동 우선순위는 Codex Pet 과 동일하게
/// Needs Input > Blocked > Ready > Running 순서다.
enum PetActivityStatus: String, Codable, CaseIterable {
    case idle
    case running
    case needsInput
    case ready
    case blocked

    fileprivate var presentationPriority: Int {
        switch self {
        case .idle: 0
        case .running: 1
        case .ready: 2
        case .blocked: 3
        case .needsInput: 4
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

    static let idle = PetPresentation(
        status: .idle,
        title: "A-mon",
        detail: nil,
        output: nil,
        provider: nil,
        sessionID: nil,
        sessionIdentity: nil,
        inputTokens: nil,
        outputTokens: nil,
        totalTokens: nil,
        updatedAt: nil,
        activeCount: 0
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

        let candidates = sessions.map { session in
            let override = overrides[session.identity]
            return Candidate(
                session: session,
                status: override?.status ?? status(from: session.status),
                title: normalizedLine(override?.title, limit: 80)
                    ?? normalizedLine(session.projectLabel, limit: 80)
                    ?? providerTitle(session.provider),
                detail: normalizedLine(override?.detail, limit: 120)
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
            .filter { $0.status == .running }
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
            output: normalizedLine(selected.session.lastResult, limit: 160),
            provider: selected.session.provider,
            sessionID: selected.session.sessionId,
            sessionIdentity: selected.session.identity,
            inputTokens: selected.session.inputTokens,
            outputTokens: selected.session.outputTokens,
            totalTokens: selected.session.totalTokens,
            updatedAt: selected.session.updatedAt,
            activeCount: activeCount
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
        guard !normalized.isEmpty else { return "A-mon" }
        return normalized.prefix(1).uppercased() + normalized.dropFirst()
    }
}

/// 단일 말풍선에서 여러 라이브 세션을 순환할 때 사용하는 순수 선택 로직.
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
