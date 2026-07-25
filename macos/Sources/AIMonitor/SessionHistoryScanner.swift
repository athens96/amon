import Foundation

/// 종료된 세션을 기록으로 만드는 스캐너 모음 (모두 오프메인에서 호출된다).
///
/// 모든 프로바이더가 **로그를 직접 읽어** 세션을 만든다 — 훅이 있는 Claude Code 도
/// 마찬가지다. 훅에만 의존하면 훅 설치 이전/다른 기기에서 만든 과거 세션이 영영
/// 안 잡히기 때문이다. Claude 는 `~/.claude/projects/**`, Codex 는
/// `~/.codex/sessions/**`, Cursor 는 전역 `state.vscdb`(`cursorDiskKV`)를 스캔하고,
/// 훅의 `pending` 은 정확한 종료 시각을 주는 보조 신호로만 쓴다.
enum SessionHistoryScanner {

    /// ISO8601DateFormatter 생성은 비싸다. 로그 한 줄마다 만들지 않고 모든 프로바이더가
    /// 같은 읽기 전용 인스턴스를 재사용한다.
    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 회귀 테스트에서 캐시 적중 시 파일 본문을 다시 읽지 않는지 확인한다.
    static var claudeBytesRead = 0
    static var codexBytesRead = 0

    // MARK: - Claude Code: 트랜스크립트 1회 파싱

    /// 트랜스크립트 한 세션에서 뽑아내는 모든 것.
    struct ClaudeTranscript {
        var usage = TokenUsage()
        var models: [String: Int] = [:]
        var prompts: [String] = []
        var promptCount = 0
        var lastResult: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var cwd: String?
        var gitBranch: String?
        var agentCount = 0
    }

    /// 사람이 친 프롬프트가 아닌 주입 텍스트(훅 스크립트의 규칙과 동일하게 유지).
    private static let nonPromptPrefixes = [
        "<command-", "<local-command", "<system-reminder", "<user-prompt-submit-hook",
    ]

    /// 본 세션 + 서브에이전트 트랜스크립트를 훑어 세션 요약을 만든다.
    ///
    /// 토큰 dedup 규칙은 `UsageScanner` 와 동일 — 한 API 응답이 콘텐츠 블록마다
    /// 반복 기록되므로 `(message.id, requestId)` 단위 last-wins (안 하면 ~2.4배 과대).
    static func parseClaudeSession(transcriptPath: String) -> ClaudeTranscript {
        var out = ClaudeTranscript()
        // 파일 간 재등장(--resume 복사)도 같은 키면 한 번만 센다.
        var byMessage: [String: (usage: TokenUsage, model: String?)] = [:]

        parseMainTranscript(URL(fileURLWithPath: transcriptPath), into: &out, usage: &byMessage)
        for file in subagentTranscripts(of: transcriptPath) {
            parseUsageOnly(file, into: &byMessage)  // 서브에이전트는 토큰만 필요하다
        }

        for (_, entry) in byMessage {
            out.usage = out.usage + entry.usage
            guard let model = entry.model, model != "<synthetic>", entry.usage.total > 0 else { continue }
            out.models[model, default: 0] += entry.usage.total
        }
        out.promptCount = out.prompts.count
        if out.prompts.count > SessionRecord.maxPrompts {
            out.prompts = Array(out.prompts.suffix(SessionRecord.maxPrompts))
        }
        return out
    }

    /// `<projects>/<session>.jsonl` 옆의 `<projects>/<session>/subagents/*.jsonl`.
    private static func subagentTranscripts(of transcriptPath: String) -> [URL] {
        let main = URL(fileURLWithPath: transcriptPath)
        let sessionID = main.deletingPathExtension().lastPathComponent
        let dir = main.deletingLastPathComponent()
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries.filter { $0.pathExtension == "jsonl" }
    }

    /// 서브에이전트 파일 — usage 있는 라인만 파싱한다(프리필터로 JSON 파싱 절약).
    private static func parseUsageOnly(
        _ file: URL, into byMessage: inout [String: (usage: TokenUsage, model: String?)]
    ) {
        guard let data = try? Data(contentsOf: file) else { return }
        claudeBytesRead += data.count
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard line.range(of: Data("\"usage\"".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            absorbUsage(obj, into: &byMessage)
        }
    }

    private static func parseMainTranscript(
        _ file: URL, into out: inout ClaudeTranscript,
        usage byMessage: inout [String: (usage: TokenUsage, model: String?)]
    ) {
        guard let data = try? Data(contentsOf: file) else { return }
        claudeBytesRead += data.count
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if let ts = (obj["timestamp"] as? String).flatMap(parseISO) {
                if out.firstTimestamp == nil { out.firstTimestamp = ts }
                out.lastTimestamp = ts
            }
            if out.cwd == nil { out.cwd = obj["cwd"] as? String }
            if out.gitBranch == nil { out.gitBranch = obj["gitBranch"] as? String }

            // 서브에이전트(sidechain) 메시지는 본 세션의 요청/응답이 아니다.
            let isSidechain = obj["isSidechain"] as? Bool ?? false
            switch obj["type"] as? String {
            case "assistant":
                absorbUsage(obj, into: &byMessage)
                guard !isSidechain, let message = obj["message"] as? [String: Any] else { break }
                let content = message["content"]
                out.agentCount += agentToolUseCount(content)
                if let text = assistantText(content) { out.lastResult = firstLine(text, 200) }
            case "user":
                // 사람이 직접 타이핑한 프롬프트만. 훅 주입·스킬 출력·task-notification
                // 같은 라인엔 promptSource 가 없거나 "system" 이다(전 트랜스크립트 실측).
                guard !isSidechain, obj["promptSource"] as? String == "typed",
                      let message = obj["message"] as? [String: Any],
                      let text = promptText(message["content"]),
                      let line = firstLine(text, 120)
                else { break }
                out.prompts.append(line)
            default:
                break
            }
        }
    }

    private static func absorbUsage(
        _ obj: [String: Any], into byMessage: inout [String: (usage: TokenUsage, model: String?)]
    ) {
        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }
        let key = "\(message["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")"
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let entry = TokenUsage(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
            reasoning: 0, total: input + output + cacheRead + cacheWrite
        )
        byMessage[key] = (entry, message["model"] as? String)  // last-wins
    }

    /// 서브에이전트를 띄우는 tool_use 블록 수(툴 이름은 버전에 따라 Agent/Task).
    private static func agentToolUseCount(_ content: Any?) -> Int {
        guard let blocks = content as? [[String: Any]] else { return 0 }
        return blocks.filter {
            $0["type"] as? String == "tool_use"
                && ["Agent", "Task"].contains($0["name"] as? String ?? "")
        }.count
    }

    /// 어시스턴트 응답에서 사람이 읽는 text 블록만.
    static func assistantText(_ content: Any?) -> String? {
        if let s = content as? String { return s.isEmpty ? nil : s }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    /// 사용자가 실제로 타이핑한 텍스트만 — tool_result 턴과 주입 텍스트는 제외.
    static func promptText(_ content: Any?) -> String? {
        if let s = content as? String { return isRealPrompt(s) ? s : nil }
        guard let blocks = content as? [[String: Any]] else { return nil }
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String, isRealPrompt(text) { return text }
        }
        return nil
    }

    private static func isRealPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !nonPromptPrefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func firstLine(_ text: String, _ limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first,
              !line.isEmpty
        else { return nil }
        return String(line.prefix(limit))
    }

    // MARK: - Claude Code: 프로젝트 로그 스캔(백필)

    /// 로컬에 남길 Claude 세션 수 상한 — 최근 파일부터.
    static let claudeSessionLimit = 200
    /// 이 시간 안에 수정된 트랜스크립트는 아직 진행 중일 수 있어 기록하지 않는다.
    static let activeGrace: TimeInterval = 15 * 60

    /// `~/.claude/projects/<project>/<session>.jsonl` 을 훑어 종료된 세션을 만든다.
    /// 지금 살아있는 세션(라이브 상태 파일이 있는 것)과 방금 수정된 것은 건너뛴다.
    static func claudeSessions(root: String) -> [SessionRecord] {
        let liveIDs = liveSessionIDs()
        let now = Date()
        guard let files = collectClaudeTranscripts(URL(fileURLWithPath: root)) else { return [] }

        let candidates = files
            .filter { !liveIDs.contains($0.deletingPathExtension().lastPathComponent) }
            .filter { (modified($0).map { now.timeIntervalSince($0) > activeGrace }) ?? false }
            .sorted { (modified($0) ?? .distantPast) > (modified($1) ?? .distantPast) }
            .prefix(claudeSessionLimit)

        var cache = SessionFileCache.load()
        let records = candidates.compactMap { claudeRecord(transcript: $0, cache: &cache) }
        SessionFileCache.save(cache)
        return records
    }

    /// 지금 라이브 상태 파일이 있는 세션 id 들.
    private static func liveSessionIDs() -> Set<String> {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: AmonPaths.live, includingPropertiesForKeys: nil
        ) else { return [] }
        return Set(files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent })
    }

    /// `<root>/<project>/<session>.jsonl` 만 — `subagents/` 하위는 제외한다.
    private static func collectClaudeTranscripts(_ root: URL) -> [URL]? {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }
        var out: [URL] = []
        for project in projects {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: project, includingPropertiesForKeys: nil
            ) else { continue }
            out.append(contentsOf: entries.filter { $0.pathExtension == "jsonl" })
        }
        return out
    }

    private static func claudeRecord(
        transcript: URL, cache: inout SessionFileCacheFile
    ) -> SessionRecord? {
        let path = transcript.path
        let key = "claude:\(path)"
        let signature = fileSetSignature([transcript] + subagentTranscripts(of: path))
        if let hit = cache.entries[key], hit.signature == signature { return hit.record }

        let parsed = parseClaudeSession(transcriptPath: path)
        guard let started = parsed.firstTimestamp, let ended = parsed.lastTimestamp,
              parsed.usage.total > 0 || !parsed.prompts.isEmpty
        else {
            cache.entries[key] = SessionFileCacheEntry(
                signature: signature, record: nil, codexState: nil
            )
            return nil
        }

        let record = SessionRecord(
            provider: "claude",
            sessionId: transcript.deletingPathExtension().lastPathComponent,
            projectLabel: parsed.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
            gitBranch: parsed.gitBranch,
            startedAt: started,
            endedAt: ended,
            prompts: parsed.prompts,
            promptCount: parsed.promptCount,
            currentTask: parsed.prompts.last,
            lastResult: parsed.lastResult,
            inputTokens: parsed.usage.input,
            outputTokens: parsed.usage.output,
            cacheTokens: parsed.usage.cacheRead + parsed.usage.cacheWrite,
            totalTokens: parsed.usage.total,
            models: parsed.models,
            agentCount: parsed.agentCount,
            sourcePath: path
        )

        cache.entries[key] = SessionFileCacheEntry(
            signature: signature, record: record, codexState: nil
        )
        return record
    }

    // MARK: - Claude Code: pending → 기록 (정확한 종료 시각 보정)

    /// `history/pending/*.json` 을 읽어 트랜스크립트 집계를 붙인 기록으로 만들고
    /// pending 파일을 지운다. 파싱 못 하는 파일도 지운다(무한 재시도 방지).
    ///
    /// 같은 세션이 `claudeSessions` 백필로도 잡히지만, pending 쪽이 훅이 기록한
    /// **정확한 종료 시각**을 갖고 있어 저장소에서 이 값이 이긴다(나중에 upsert).
    static func ingestPending() -> [SessionRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: AmonPaths.pending, includingPropertiesForKeys: nil
        ) else { return [] }

        var records: [SessionRecord] = []
        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let dto = try? AmonJSON.decoder().decode(PendingSession.self, from: data)
            else { continue }
            let record = record(from: dto)
            // 토큰도 요청도 없는 세션(트랜스크립트를 못 찾은 구버전 상태 파일 등)은
            // 기록할 내용이 없다 — 빈 줄로 목록을 더럽히지 않는다.
            guard record.totalTokens > 0 || !record.prompts.isEmpty else { continue }
            records.append(record)
        }
        return records
    }

    /// 훅이 SessionEnd 때 떨궈 둔 세션 상태(라이브 상태 + ended_at).
    private struct PendingSession: Decodable {
        let provider: String?
        let session_id: String
        let project_label: String
        let git_branch: String?
        let current_task: String?
        let last_result: String?
        let transcript_path: String?
        let agent_total: Int?
        let started_at: Date
        let ended_at: Date
    }

    private static func record(from dto: PendingSession) -> SessionRecord {
        let parsed = dto.transcript_path.map { parseClaudeSession(transcriptPath: $0) }
        let usage = parsed?.usage ?? TokenUsage()
        return SessionRecord(
            provider: dto.provider ?? "claude",
            sessionId: dto.session_id,
            projectLabel: dto.project_label,
            gitBranch: dto.git_branch,
            startedAt: parsed?.firstTimestamp ?? dto.started_at,
            endedAt: dto.ended_at,
            prompts: parsed?.prompts ?? [],
            promptCount: parsed?.promptCount ?? 0,
            currentTask: parsed?.prompts.last ?? dto.current_task,
            lastResult: dto.last_result ?? parsed?.lastResult,
            inputTokens: usage.input,
            outputTokens: usage.output,
            cacheTokens: usage.cacheRead + usage.cacheWrite,
            totalTokens: usage.total,
            models: parsed?.models ?? [:],
            agentCount: dto.agent_total ?? parsed?.agentCount ?? 0,
            sourcePath: dto.transcript_path
        )
    }

    // MARK: - 크래시로 남은 라이브 세션 회수

    /// 이보다 오래 갱신이 없으면 SessionEnd 를 못 받고 죽은 세션으로 본다.
    ///
    /// 화면에서 숨기는 기준(15분, `LiveActivityManager`)보다 훨씬 길게 잡는다 —
    /// 사용자가 자리를 비운 **살아있는 유휴 세션**을 종료로 기록해 버리면
    /// 그 세션이 다시 응답할 때 기록이 어긋난다(실측으로 확인).
    static let archiveAfter: TimeInterval = 6 * 60 * 60

    /// `updated_at` 이 `archiveAfter` 보다 오래된 라이브 세션은 죽은 것으로 보고
    /// pending 으로 옮긴다(종료 시각 = 마지막 갱신 시각).
    static func sweepStaleLiveSessions(staleInterval: TimeInterval = archiveAfter) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: AmonPaths.live, includingPropertiesForKeys: nil
        ) else { return }
        let now = Date()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let updated = obj["updated_at"] as? String,
                  let updatedAt = parseISO(updated),
                  now.timeIntervalSince(updatedAt) > staleInterval
            else { continue }

            obj["ended_at"] = updated  // 마지막으로 살아있던 시각을 종료 시각으로
            let dest = AmonPaths.pending.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.createDirectory(
                at: AmonPaths.pending, withIntermediateDirectories: true
            )
            guard let blob = try? JSONSerialization.data(withJSONObject: obj),
                  (try? blob.write(to: dest, options: .atomic)) != nil
            else { continue }  // 옮기지 못하면 라이브 파일을 지우지 않는다
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func parseISO(_ s: String) -> Date? {
        fractionalISO.date(from: s) ?? plainISO.date(from: s)
    }

    // MARK: - Codex CLI: rollout 로그 → 기록

    /// 로컬에 남길 Codex 세션 수 상한 — 최근 파일부터.
    static let codexSessionLimit = 200

    /// `~/.codex/sessions/**/rollout-*.jsonl` 에서 종료된 세션을 만든다.
    ///
    /// 누적 토큰은 파일별 **마지막 `total_token_usage` 스냅샷**만 쓴다(라인 합산 금지).
    /// `cached_input_tokens` 는 input 의 부분집합이라 분리해 담는다.
    static func codexSessions(root: String) -> [SessionRecord] {
        let rootURL = URL(fileURLWithPath: root)
        guard let files = collectRollouts(rootURL) else { return [] }
        let recent = files
            .sorted { (modified($0) ?? .distantPast) > (modified($1) ?? .distantPast) }
            .prefix(codexSessionLimit)
        var cache = SessionFileCache.load()
        let records = recent.compactMap { parseCodexRollout($0, cache: &cache) }
        SessionFileCache.save(cache)
        return records
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

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func parseCodexRollout(
        _ file: URL, cache: inout SessionFileCacheFile
    ) -> SessionRecord? {
        let key = "codex:\(file.path)"
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(max(0, values?.fileSize ?? 0))
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let signature = "\(size)|\(mtime)"
        if let hit = cache.entries[key], hit.signature == signature { return hit.record }

        var state = cache.entries[key]?.codexState ?? CodexRolloutState()
        if size < state.offset { state = CodexRolloutState() }
        guard let chunk = readCompleteLines(file, from: state.offset) else { return nil }
        codexBytesRead += chunk.data.count

        for line in chunk.data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if let ts = (obj["timestamp"] as? String).flatMap(parseISO) {
                if state.firstTimestamp == nil { state.firstTimestamp = ts }
                state.lastTimestamp = ts
            }
            guard let payload = obj["payload"] as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "session_meta":
                state.sessionID = payload["id"] as? String ?? state.sessionID
                state.cwd = payload["cwd"] as? String ?? state.cwd
            case "turn_context":
                state.cwd = payload["cwd"] as? String ?? state.cwd
                state.model = payload["model"] as? String ?? state.model
            case "event_msg":
                switch payload["type"] as? String {
                case "token_count":
                    guard let info = payload["info"] as? [String: Any],
                          let total = info["total_token_usage"] as? [String: Any]
                    else { break }
                    let rawInput = total["input_tokens"] as? Int ?? 0
                    let cached = total["cached_input_tokens"] as? Int ?? 0
                    let output = total["output_tokens"] as? Int ?? 0
                    state.lastUsage = TokenUsage(
                        input: max(0, rawInput - cached), output: output,
                        cacheRead: cached, cacheWrite: 0, reasoning: 0,
                        total: total["total_tokens"] as? Int ?? (rawInput + output)
                    )
                case "user_message":
                    appendCodexPrompt(payload["message"] as? String, to: &state)
                default:
                    break
                }
            case "response_item":
                if let text = codexUserMessage(from: payload) {
                    appendCodexPrompt(text, to: &state)
                } else if let text = codexAssistantText(from: payload),
                          let line = codexFirstLine(text, limit: 200) {
                    state.lastResult = line
                }
            default:
                break
            }
        }
        state.offset = chunk.nextOffset

        let record: SessionRecord?
        if let id = state.sessionID, let started = state.firstTimestamp,
           let ended = state.lastTimestamp, let usage = state.lastUsage, usage.total > 0 {
            let label = state.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let modelName = state.model ?? "unknown"
            record = SessionRecord(
            provider: "codex",
            sessionId: id,
            projectLabel: label,
            gitBranch: nil,  // rollout 로그엔 브랜치 정보가 없다
            startedAt: started,
            endedAt: ended,
            prompts: Array(state.prompts.suffix(SessionRecord.maxPrompts)),
            promptCount: state.promptCount,
            currentTask: state.prompts.last,
            lastResult: state.lastResult,
            inputTokens: usage.input,
            outputTokens: usage.output,
            cacheTokens: usage.cacheRead + usage.cacheWrite,
            totalTokens: usage.total,
            models: [modelName: usage.total],
            agentCount: 0,
            sourcePath: file.path
            )
        } else {
            record = nil
        }
        cache.entries[key] = SessionFileCacheEntry(
            signature: signature, record: record, codexState: state
        )
        return record
    }

    private static func appendCodexPrompt(_ text: String?, to state: inout CodexRolloutState) {
        guard let line = codexFirstLine(text, limit: 120),
              state.seenPrompts.insert(line).inserted
        else { return }
        state.prompts.append(line)
        if state.prompts.count > SessionRecord.maxPrompts {
            state.prompts.removeFirst(state.prompts.count - SessionRecord.maxPrompts)
        }
        state.promptCount += 1
    }

    private static func readCompleteLines(
        _ file: URL, from offset: UInt64
    ) -> (data: Data, nextOffset: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let tail = try handle.readToEnd() ?? Data()
            guard let newline = tail.lastIndex(of: UInt8(ascii: "\n")) else {
                return (Data(), offset)
            }
            let end = tail.index(after: newline)
            return (Data(tail[..<end]), offset + UInt64(end))
        } catch {
            return nil
        }
    }

    private static func fileSetSignature(_ files: [URL]) -> String {
        let parts = files.map { file -> String in
            let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            return "\(file.path)|\(values?.fileSize ?? -1)|" +
                "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.sorted().joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - Cursor: 전역 state.vscdb → 기록

    /// 로컬에 남길 Cursor 세션(composer) 수 상한 — 최근 것부터.
    static let cursorSessionLimit = 200

    /// 전역 `cursorDiskKV` 의 composer 를 종료 세션 기록으로 만든다.
    ///
    /// 마지막 갱신이 `activeGrace` 안쪽인 composer 는 아직 진행 중일 수 있어
    /// 건너뛴다(라이브 화면 담당). 최신 Cursor 는 로컬 DB 버블에 tokenCount 를
    /// 더 이상 남기지 않으므로, 토큰은 대시보드 CSV 이벤트를 버블 시각에 귀속한
    /// **추정치**로 채운다(`CursorSessionTokens` — 이벤트가 없으면 0). 추정은
    /// 캐시된 기록에 저장하지 않고 스캔마다 다시 입힌다 — 뒤늦게 도착한 이벤트가
    /// 다음 스캔에서 자연히 반영되게.
    static func cursorSessions(dbPath: String) -> [SessionRecord] {
        guard let dbURL = CursorStateDB.resolveGlobalDB(from: dbPath) else { return [] }
        let now = Date()
        let records = CursorStateDB.withDB(dbURL) { db -> [SessionRecord] in
            let ended = CursorStateDB.composerMetas(db)
                .filter { meta in
                    guard let updated = meta.updatedAt else { return false }
                    return now.timeIntervalSince(updated) > activeGrace
                }
                .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                .prefix(cursorSessionLimit)
            guard !ended.isEmpty else { return [] }

            var cache = SessionFileCache.load()
            var out: [SessionRecord] = []
            var bubbleTimes: [String: [Date]] = [:]  // 세션 id → 버블 시각(귀속 입력)
            var misses: [CursorStateDB.ComposerMeta] = []
            for meta in ended {
                // 버블 시각이 없는 항목(추정 도입 전 캐시)은 미스로 취급해 다시 파싱.
                if let hit = cache.entries["cursor:\(meta.id)"],
                   hit.signature == cursorSignature(meta),
                   let bubbles = hit.cursorBubbleTimes {
                    if let record = hit.record {
                        out.append(record)
                        bubbleTimes[record.sessionId] = bubbles
                    }
                } else {
                    misses.append(meta)
                }
            }

            if !misses.isEmpty {
                let labels = CursorStateDB.workspaceLabels(near: dbURL, for: Set(misses.map(\.id)))
                for meta in misses {
                    let built = cursorRecord(db, meta: meta, label: labels[meta.id], dbPath: dbURL.path)
                    cache.entries["cursor:\(meta.id)"] = SessionFileCacheEntry(
                        signature: cursorSignature(meta), record: built?.record, codexState: nil,
                        cursorBubbleTimes: built?.bubbles ?? []
                    )
                    if let built {
                        out.append(built.record)
                        bubbleTimes[built.record.sessionId] = built.bubbles
                    }
                }
                SessionFileCache.save(cache)
            }
            return applyTokenEstimates(to: out, bubbleTimes: bubbleTimes)
        }
        return records ?? []
    }

    /// CSV 이벤트를 최근접 버블 세션에 귀속해 추정 토큰/모델을 입힌다.
    /// 이벤트 캐시가 비어 있으면 기록을 그대로 둔다(0 유지).
    private static func applyTokenEstimates(
        to records: [SessionRecord], bubbleTimes: [String: [Date]]
    ) -> [SessionRecord] {
        let estimates = CursorSessionTokens.attribute(
            events: CursorSessionTokens.events(),
            sessions: records.compactMap { record in
                bubbleTimes[record.sessionId].map { (id: record.sessionId, bubbles: $0) }
            }
        )
        guard !estimates.isEmpty else { return records }
        return records.map { record in
            guard let estimate = estimates[record.sessionId] else { return record }
            var copy = record
            copy.inputTokens = estimate.usage.input
            copy.outputTokens = estimate.usage.output
            copy.cacheTokens = estimate.usage.cacheRead + estimate.usage.cacheWrite
            copy.totalTokens = estimate.usage.total
            if !estimate.models.isEmpty { copy.models = estimate.models }
            return copy
        }
    }

    /// composer 는 파일이 아니라 DB 행이라 (size, mtime) 대신 lastUpdatedAt 이 지문이다.
    private static func cursorSignature(_ meta: CursorStateDB.ComposerMeta) -> String {
        "\(meta.updatedAt?.timeIntervalSince1970 ?? 0)"
    }

    /// 기록과 함께 버블 시각들을 돌려준다 — 캐시에 저장돼 토큰 추정 귀속에 쓰인다.
    private static func cursorRecord(
        _ db: OpaquePointer, meta: CursorStateDB.ComposerMeta, label: String?, dbPath: String
    ) -> (record: SessionRecord, bubbles: [Date])? {
        guard let composer = CursorStateDB.composer(db, id: meta.id) else { return nil }

        // type 1(user) 버블 본문 첫 줄이 곧 요청 목록. 빈 본문(컨텍스트 전용 버블)은
        // 요청이 아니다.
        var prompts: [String] = []
        for header in composer.headers where header.type == 1 {
            guard let bubble = CursorStateDB.bubble(
                db, composerId: composer.id, bubbleId: header.bubbleId
            ), !bubble.text.isEmpty,
                let line = CursorStateDB.firstLine(bubble.text, 120)
            else { continue }
            prompts.append(line)
        }
        // 요청이 하나도 없는 composer(빈 초안 등)는 기록할 내용이 없다.
        guard !prompts.isEmpty else { return nil }
        let promptCount = prompts.count
        if prompts.count > SessionRecord.maxPrompts {
            prompts = Array(prompts.suffix(SessionRecord.maxPrompts))
        }

        let started = composer.createdAt
            ?? composer.headers.first?.createdAt
            ?? meta.updatedAt
            ?? Date()
        let ended = composer.updatedAt ?? meta.updatedAt ?? started
        let record = SessionRecord(
            provider: "cursor",
            sessionId: composer.id,
            projectLabel: label ?? "Cursor",
            gitBranch: nil,  // 전역 DB 에는 브랜치 정보가 없다
            startedAt: started,
            endedAt: ended,
            prompts: prompts,
            promptCount: promptCount,
            currentTask: prompts.last,
            lastResult: CursorStateDB.latestText(db, composer: composer, type: 2, limit: 200),
            inputTokens: 0,  // 추정은 applyTokenEstimates 가 스캔마다 입힌다
            outputTokens: 0,
            cacheTokens: 0,
            totalTokens: 0,
            models: composer.modelName.map { [$0: 0] } ?? [:],
            agentCount: composer.subagentCount,
            sourcePath: dbPath
        )
        return (record, composer.headers.compactMap(\.createdAt))
    }

    static func codexUserMessage(from payload: [String: Any]) -> String? {
        guard payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]]
        else { return nil }
        for block in content where block["type"] as? String == "input_text" {
            guard let text = block["text"] as? String,
                  codexIsRealUserMessage(text)
            else { continue }
            return text
        }
        return nil
    }

    static func codexAssistantText(from payload: [String: Any]) -> String? {
        guard payload["type"] as? String == "message",
              payload["role"] as? String == "assistant"
        else { return nil }
        if let content = payload["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                let type = block["type"] as? String
                guard type == "output_text" || type == "text" else { return nil }
                return block["text"] as? String
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        return payload["text"] as? String
    }

    static func codexIsRealUserMessage(_ text: String) -> Bool {
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

    private static func codexFirstLine(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first,
              !line.isEmpty
        else { return nil }
        return String(line.prefix(limit))
    }
}
