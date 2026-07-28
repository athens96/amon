import Foundation
import SQLite3

/// 세션 내에서 현재 실행 중인 서브에이전트 1개(로컬 상태 파일에서 파싱).
struct LiveAgent: Equatable {
    let toolUseId: String
    let agentType: String
    let description: String
    let startedAt: Date
}

/// 한 Claude Code 세션의 최신 라이브 상태(로컬 상태 파일 1개에 대응).
struct LiveSession: Equatable {
    /// ProviderIcons 의 id 와 동일("claude" | "codex" | "cursor").
    let provider: String
    let sessionId: String
    /// 로컬 SwiftUI 목록에서 서로 다른 도구의 같은 세션 ID가 충돌하지 않게 한다.
    var identity: String { "\(provider):\(sessionId)" }
    let projectLabel: String
    let gitBranch: String?
    let status: String
    let agents: [LiveAgent]
    /// 가장 최근 사용자 프롬프트의 첫 줄(최대 120자) — 훅이 트랜스크립트에서 직접
    /// 추출. 전체 프롬프트는 절대 저장하지 않는다.
    let currentTask: String?
    /// 직전 턴의 응답 첫 줄(최대 200자). 턴이 끝났을 때(Stop)만 채워진다.
    let lastResult: String?
    /// 현재 세션에서 마지막으로 확인한 모델 ID. 없으면 nil.
    let model: String?
    /// 라이브 토큰 스냅샷. Codex 는 세션 누적값, Claude/Cursor 는 로그에 있는 최신 값이다.
    /// 전체 프롬프트/응답 원문은 현재 활동 캐시에 저장하지 않는다.
    let totalTokens: Int?
    /// 입력/출력 토큰 분해값. 제공자가 안전하게 노출하는 경우에만 채운다.
    let inputTokens: Int?
    let outputTokens: Int?
    let startedAt: Date
    let updatedAt: Date

    init(
        provider: String,
        sessionId: String,
        projectLabel: String,
        gitBranch: String?,
        status: String,
        agents: [LiveAgent],
        currentTask: String?,
        lastResult: String?,
        model: String?,
        totalTokens: Int?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.projectLabel = projectLabel
        self.gitBranch = gitBranch
        self.status = status
        self.agents = agents
        self.currentTask = currentTask
        self.lastResult = lastResult
        self.model = model
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

/// 기존 설치와 공유하는 레거시 `~/Library/Application Support/A-mon/live/*.json` 를
/// 주기적으로 폴링해 살아있는
/// Claude Code 세션 스냅샷을 유지하는 관찰가능 상태.
///
/// `LiveProvidersManager` 와 같은 형태의 자체 타이머로 훅 스크립트가 써 둔 로컬
/// 디렉토리를 읽는다. 파싱은 `.utility` 로 오프메인에서 돈다.
@MainActor
final class LiveActivityManager: ObservableObject {
    /// 현재 살아있는(15분 내 갱신된) 세션들.
    @Published private(set) var sessions: [LiveSession] = []

    private var autoTask: Task<Void, Never>?
    /// 폴링 간격 — 5초.
    private let interval: TimeInterval = 5
    /// Codex CLI rollout 로그 루트. Codex 는 훅이 없어서 이 경로를 짧게 폴링한다.
    var codexRoot: String = ""
    /// Cursor 전역 state.vscdb 경로. Cursor 는 훅이 없어서 cursorDiskKV 를 폴링한다.
    var cursorPath: String = ""

    var liveDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/A-mon/live", isDirectory: true)
    }

    /// 즉시 1회 폴링하고 이후 주기 타이머를 건다. 켜진 상태에서 중복 시작은 무시.
    func start() {
        guard autoTask == nil else { return }
        autoTask = Task { [weak self] in
            guard let interval = self?.interval else { return }
            await self?.poll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.poll()
            }
        }
    }

    /// 폴링을 멈춘다(토글 OFF).
    func stop() {
        autoTask?.cancel()
        autoTask = nil
        sessions = []
    }

    /// 라이브 디렉토리를 오프메인에서 파싱하고, 직전과 다르면 반영·통지한다.
    func poll() async {
        let dir = liveDir
        let codexRoot = codexRoot
        let cursorPath = cursorPath
        let parsed = await Task.detached(priority: .utility) {
            LiveSessionParser.load(from: dir, codexRoot: codexRoot, cursorPath: cursorPath)
        }.value
        if parsed != sessions {
            sessions = parsed
        }
    }
}

/// 라이브 세션 상태 파일 파싱기 — 오프메인(detached)에서 돌 수 있게 액터 격리 없이 둔다.
enum LiveSessionParser {
    /// 이보다 오래 갱신 안 된 세션은 stale(크래시/좀비)로 보고 로컬 목록에서 버린다.
    static let staleInterval: TimeInterval = 15 * 60

    /// 디렉토리의 *.json 을 파싱하고 stale 세션을 제거해 startedAt 순으로 정렬한다.
    /// 정렬은 디렉토리 순서 변동으로 인한 헛된 "변경" 을 막아 안정적 비교를 보장한다.
    static func load(from dir: URL, codexRoot: String, cursorPath: String) -> [LiveSession] {
        var result = loadClaude(from: dir)
        result.append(contentsOf: CodexLiveParser.load(from: codexRoot))
        result.append(contentsOf: CursorLiveParser.load(from: cursorPath))
        return result.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.provider < $1.provider
            }
            return $0.startedAt < $1.startedAt
        }
    }

    private static func loadClaude(from dir: URL) -> [LiveSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let now = Date()
        let decoder = makeDecoder()
        var result: [LiveSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let dto = try? decoder.decode(SessionDTO.self, from: data)
            else { continue }
            if now.timeIntervalSince(dto.updated_at) > staleInterval { continue }
            result.append(dto.toModel())
        }
        return result
    }

    private static func makeDecoder() -> JSONDecoder {
        // 훅은 tz-aware ISO8601 을 쓴다(microsecond 제거). 소수초 유무 모두 견디게 폴백.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = fractional.date(from: s) ?? plain.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "잘못된 ISO8601 날짜: \(s)"
            )
        }
        return decoder
    }

    // 디코딩 DTO (snake_case — 코드베이스 리포터 컨벤션과 동일)

    private struct SessionDTO: Decodable {
        let provider: String?
        let session_id: String
        let project_label: String
        let git_branch: String?
        let status: String
        let agents: [AgentDTO]
        let current_task: String?
        let last_result: String?
        let model: String?
        let total_tokens: Int?
        let input_tokens: Int?
        let output_tokens: Int?
        let started_at: Date
        let updated_at: Date

        func toModel() -> LiveSession {
            LiveSession(
                provider: provider ?? "claude",
                sessionId: session_id,
                projectLabel: project_label,
                gitBranch: git_branch,
                status: status,
                agents: agents.map { $0.toModel() },
                currentTask: current_task,
                lastResult: last_result,
                model: model,
                totalTokens: total_tokens,
                inputTokens: input_tokens,
                outputTokens: output_tokens,
                startedAt: started_at,
                updatedAt: updated_at
            )
        }
    }

    private struct AgentDTO: Decodable {
        let tool_use_id: String
        let agent_type: String
        let description: String
        let started_at: Date

        func toModel() -> LiveAgent {
            LiveAgent(
                toolUseId: tool_use_id,
                agentType: agent_type,
                description: description,
                startedAt: started_at
            )
        }
    }
}

/// Codex CLI 는 Claude Code 같은 lifecycle hook 이 없으므로 rollout 로그의 최근
/// 수정 시각과 마지막 token_count 스냅샷을 라이브 상태로 해석한다.
enum CodexLiveParser {
    static let staleInterval: TimeInterval = 15 * 60
    static let activeInterval: TimeInterval = 90
    static let maxFiles = 20

    static func load(from root: String) -> [LiveSession] {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let rootURL = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        guard let files = collectRollouts(rootURL) else { return [] }
        let now = Date()
        return files
            .compactMap { file -> (URL, Date)? in
                guard let mtime = modified(file),
                      now.timeIntervalSince(mtime) <= staleInterval
                else { return nil }
                return (file, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maxFiles)
            .compactMap { parse($0.0, modifiedAt: $0.1, now: now) }
    }

    private static func collectRollouts(_ root: URL) -> [URL]? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return nil }
        var out: [URL] = []
        for case let url as URL in e
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            out.append(url)
        }
        return out
    }

    private static func parse(_ file: URL, modifiedAt: Date, now: Date) -> LiveSession? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        var sessionID: String?
        var cwd: String?
        var model: String?
        var firstTS: Date?
        var lastTS: Date?
        var lastTotalTokens: Int?
        var lastInputTokens: Int?
        var lastOutputTokens: Int?
        var currentTask: String?
        var lastResult: String?
        var hasTaskLifecycle = false
        var taskIsActive = false

        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if let ts = (obj["timestamp"] as? String).flatMap(parseISO) {
                if firstTS == nil { firstTS = ts }
                lastTS = ts
            }
            guard let payload = obj["payload"] as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "session_meta":
                sessionID = payload["id"] as? String ?? sessionID
                cwd = payload["cwd"] as? String ?? cwd
            case "turn_context":
                cwd = payload["cwd"] as? String ?? cwd
                model = payload["model"] as? String ?? model
            case "event_msg":
                switch payload["type"] as? String {
                case "task_started", "turn_started":
                    hasTaskLifecycle = true
                    taskIsActive = true
                case "task_complete", "turn_complete", "turn_aborted":
                    hasTaskLifecycle = true
                    taskIsActive = false
                case "token_count":
                    guard let info = payload["info"] as? [String: Any],
                          let total = info["total_token_usage"] as? [String: Any]
                    else { break }
                    let rawInputTokens = intValue(total["input_tokens"])
                    let cachedInputTokens = intValue(total["cached_input_tokens"]) ?? 0
                    lastInputTokens = rawInputTokens.map { max($0 - cachedInputTokens, 0) }
                    lastOutputTokens = intValue(total["output_tokens"])
                    lastTotalTokens = intValue(total["total_tokens"])
                        ?? componentTotal(input: rawInputTokens, output: lastOutputTokens)
                case "user_message":
                    if let text = firstLine(
                        payload["message"] as? String ?? payload["text"] as? String,
                        limit: 120
                    ) {
                        currentTask = text
                        lastResult = nil
                    }
                case "agent_message":
                    if let text = agentEventPreview(
                        payload["message"] as? String ?? payload["text"] as? String,
                        limit: 200
                    ) {
                        lastResult = text
                    }
                default:
                    break
                }
            case "response_item":
                if payload["type"] as? String == "message" {
                    switch payload["role"] as? String {
                    case "user":
                        if let text = extractMessageText(
                            from: payload, blockTypes: ["input_text", "text"], limit: 120
                        ),
                           isRealUserMessage(text) {
                            currentTask = text
                            lastResult = nil
                        }
                    case "assistant":
                        if let text = extractMessageText(
                            from: payload, blockTypes: ["output_text", "text"], limit: 200
                        ) {
                            lastResult = text
                        } else if let text = firstLine(
                            payload["text"] as? String ?? payload["message"] as? String,
                            limit: 200
                        ) {
                            lastResult = text
                        }
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        guard let id = sessionID, let started = firstTS else { return nil }
        let projectLabel = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
        // 최신 Codex rollout은 턴 lifecycle을 명시하므로 파일 mtime보다 우선한다.
        // 구버전 로그만 기존 90초 갱신 추정값을 사용한다.
        let status = hasTaskLifecycle
            ? (taskIsActive ? "active" : "idle")
            : (now.timeIntervalSince(modifiedAt) <= activeInterval ? "active" : "idle")
        let task = currentTask ?? summary(model: model, totalTokens: lastTotalTokens)
        return LiveSession(
            provider: "codex",
            sessionId: id,
            projectLabel: projectLabel,
            gitBranch: nil,
            status: status,
            agents: [],
            currentTask: task,
            lastResult: lastResult,
            model: model,
            totalTokens: lastTotalTokens,
            inputTokens: lastInputTokens,
            outputTokens: lastOutputTokens,
            startedAt: started,
            updatedAt: lastTS ?? modifiedAt
        )
    }

    private static func summary(model: String?, totalTokens: Int?) -> String? {
        let modelPart = model.map { "model \($0)" }
        let tokenPart = totalTokens.map { "\($0.formatted()) tokens" }
        return [modelPart, tokenPart].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private static func extractMessageText(
        from payload: [String: Any],
        blockTypes: Set<String>,
        limit: Int
    ) -> String? {
        guard let content = payload["content"] as? [[String: Any]]
        else { return nil }
        for block in content where blockTypes.contains(block["type"] as? String ?? "") {
            if let text = firstLine(block["text"] as? String, limit: limit) {
                return text
            }
        }
        return nil
    }

    private static func isRealUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let skippedPrefixes = [
            "# AGENTS.md instructions",
            "<INSTRUCTIONS>",
            "<environment_context>",
            "<permissions instructions>",
        ]
        return !skippedPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// `event_msg.agent_message`에는 권한 판정 같은 내부 구조화 이벤트가 섞일 수 있다.
    /// 완전한 JSON 여부를 200자 미리보기에서 다시 파싱하면 긴/멀티라인 JSON이
    /// 잘려 통과하므로, 이벤트 경로에서만 구조화 텍스트 시작 문자를 제외한다.
    private static func agentEventPreview(_ text: String?, limit: Int) -> String? {
        guard let preview = firstLine(text, limit: limit) else { return nil }
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return nil }
        return preview
    }

    private static func firstLine(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first,
              !line.isEmpty
        else { return nil }
        return String(line.prefix(limit))
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value >= 0 ? value : nil }
        if let value = value as? NSNumber {
            let parsed = value.intValue
            return parsed >= 0 ? parsed : nil
        }
        return nil
    }

    private static func componentTotal(input: Int?, output: Int?) -> Int? {
        guard input != nil || output != nil else { return nil }
        return (input ?? 0) + (output ?? 0)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func parseISO(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

/// Cursor 는 Claude/Codex 처럼 안정적인 세션 JSONL 이 없다. 최신 Cursor 는 대화를
/// **전역** `state.vscdb` 의 `cursorDiskKV`(`composerData:*` + `bubbleId:*`)에 저장
/// 하므로 그 테이블을 폴링한다(`CursorStateDB` 공유 구현). workspace `ItemTable` 은
/// 마이그레이션 후 ID 목록만 남아 더 이상 파싱 대상이 아니다. 토큰은 v3.x 부터
/// 로컬 DB 에 남지 않아(소비량은 클라우드 CSV 로만) 라이브에서도 채우지 않는다.
private enum CursorLiveParser {
    static let staleInterval: TimeInterval = 15 * 60
    static let activeInterval: TimeInterval = 90
    /// 동시에 보여줄 최근 composer 수 상한.
    static let maxSessions = 8

    /// 직전 폴링 결과 메모 — DB(-wal 포함) fingerprint 가 같으면 재파싱하지 않는다.
    /// 5초 폴링마다 composer 목록 스캔(~50ms)을 반복하지 않기 위한 것. status 는
    /// 시간이 흐르면 바뀌므로(작업 중→대기) 반환 시점에 다시 계산한다.
    private static let memoLock = NSLock()
    private static var memoSignature = ""
    private static var memoSessions: [LiveSession] = []

    static func load(from path: String) -> [LiveSession] {
        guard let dbURL = CursorStateDB.resolveGlobalDB(from: path) else { return [] }
        let now = Date()
        // 본 파일 mtime 은 체크포인트 전까지 며칠씩 멈춰 있어 -wal 까지 본다.
        guard let touched = CursorStateDB.lastModified(dbURL),
              now.timeIntervalSince(touched) <= staleInterval
        else { return [] }

        let signature = CursorStateDB.signature(dbURL) + "|" + tokenCacheSignature()
        memoLock.lock()
        let cached: [LiveSession]? = memoSignature == signature ? memoSessions : nil
        memoLock.unlock()
        if let cached { return refreshed(cached, now: now) }

        let parsed = parse(dbURL, now: now)
        memoLock.lock()
        memoSignature = signature
        memoSessions = parsed
        memoLock.unlock()
        return refreshed(parsed, now: now)
    }

    /// Cursor 사용 이벤트 캐시만 새로 받아도 세션 토큰 추정치를 다시 계산한다.
    private static func tokenCacheSignature() -> String {
        let url = CursorSessionTokens.fileURL
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return "no-token-cache" }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(modified):\(values.fileSize ?? 0)"
    }

    /// 메모/파싱 결과에 현재 시각 기준 stale 필터·status 를 다시 입힌다.
    private static func refreshed(_ sessions: [LiveSession], now: Date) -> [LiveSession] {
        sessions.compactMap { session in
            guard now.timeIntervalSince(session.updatedAt) <= staleInterval else { return nil }
            return LiveSession(
                provider: session.provider,
                sessionId: session.sessionId,
                projectLabel: session.projectLabel,
                gitBranch: session.gitBranch,
                status: now.timeIntervalSince(session.updatedAt) <= activeInterval
                    ? "active" : "idle",
                agents: session.agents,
                currentTask: session.currentTask,
                lastResult: session.lastResult,
                model: session.model,
                totalTokens: session.totalTokens,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                startedAt: session.startedAt,
                updatedAt: session.updatedAt
            )
        }
    }

    private static func parse(_ dbURL: URL, now: Date) -> [LiveSession] {
        let cutoff = now.addingTimeInterval(-staleInterval)
        let sessions = CursorStateDB.withDB(dbURL) { db -> [LiveSession] in
            let recent = CursorStateDB.composerMetas(db)
                .filter { ($0.updatedAt ?? .distantPast) >= cutoff }
                .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                .prefix(maxSessions)
            guard !recent.isEmpty else { return [] }

            let labels = CursorStateDB.workspaceLabels(near: dbURL, for: Set(recent.map(\.id)))
            let composers = recent.compactMap { meta -> CursorStateDB.Composer? in
                CursorStateDB.composer(db, id: meta.id)
            }
            // 토큰은 로컬에 없어 CSV 이벤트 귀속 추정치를 쓴다(세션 기록과 동일 규칙,
            // 캐시가 비어 있으면 nil 유지). 이벤트 갱신은 사용량/기록 스캔이 담당.
            let estimates = CursorSessionTokens.attribute(
                events: CursorSessionTokens.events(),
                sessions: composers.map { ($0.id, $0.headers.compactMap(\.createdAt)) }
            )
            return composers.compactMap { composer -> LiveSession? in
                guard let updated = composer.updatedAt else { return nil }
                let task = CursorStateDB.latestText(db, composer: composer, type: 1, limit: 120)
                    ?? composer.name
                // 요약할 내용이 아무것도 없는 composer(빈 초안)는 표시하지 않는다.
                guard task != nil else { return nil }
                let estimate = estimates[composer.id]
                return LiveSession(
                    provider: "cursor",
                    sessionId: composer.id,
                    projectLabel: labels[composer.id] ?? "Cursor",
                    gitBranch: nil,
                    status: "idle",  // refreshed() 가 현재 시각으로 다시 계산한다
                    agents: [],
                    currentTask: task,
                    lastResult: CursorStateDB.latestText(db, composer: composer, type: 2, limit: 200),
                    model: composer.modelName
                        ?? estimate?.models.max(by: { $0.value < $1.value })?.key,
                    totalTokens: (estimate?.usage.total).flatMap { $0 > 0 ? $0 : nil },
                    inputTokens: (estimate?.usage.input).flatMap { $0 > 0 ? $0 : nil },
                    outputTokens: (estimate?.usage.output).flatMap { $0 > 0 ? $0 : nil },
                    startedAt: composer.createdAt ?? updated,
                    updatedAt: updated
                )
            }
        }
        return sessions ?? []
    }
}
