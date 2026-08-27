import Foundation

/// 세션 상세 화면의 대화 한 턴 — 요청 또는 응답의 **전체 본문**.
///
/// 목록(`SessionRecord`)이 갖고 있는 건 첫 줄 요약뿐이라 응답이 잘려 보인다.
/// 상세는 원본 로그를 열어 요청·응답을 시간순 그대로 복원한다.
struct TranscriptTurn: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: Int
    let role: Role
    let text: String
    let timestamp: Date?
    /// 이 요청이 유발한 **턴 사용량** — 이 요청부터 다음 요청 전까지의 API 실측 합.
    /// user 턴에만 붙는다. input 은 입력 텍스트가 아니라 시스템 프롬프트·이전
    /// 대화를 포함한 요청 컨텍스트 전체다. Cursor 는 턴 단위 실측이 없어 항상 nil.
    var usage: TokenUsage? = nil
}

enum TranscriptError: LocalizedError, Equatable {
    /// 원본 로그가 지워졌거나(로그 정리) 다른 기기에서 만든 세션.
    case sourceNotFound
    case unreadable
    /// 파일은 읽었지만 사람이 읽을 요청·응답이 없다(툴 호출만 있는 세션 등).
    case empty

    var errorDescription: String? {
        switch self {
        case .sourceNotFound: return "원본 로그를 찾을 수 없습니다"
        case .unreadable: return "원본 로그를 읽지 못했습니다"
        case .empty: return "표시할 대화 내용이 없습니다"
        }
    }
}

/// 종료 세션의 원본 로그를 **상세를 열 때 그 자리에서** 읽어 전체 대화를 만든다.
///
/// 미리 읽어 두지 않는 이유: 트랜스크립트는 세션당 수 MB까지 가고 기록은 수백 건이라
/// 전부 들고 있으면 메모리·CPU 낭비다. 목록은 스캐너가 만든 요약만 쓰고, 본문은
/// 클릭한 한 세션에 대해서만 읽는다. 결과는 저장하지도, 서버로 보내지도 않는다.
///
/// 파싱 규칙(사람 프롬프트 판별·어시스턴트 텍스트 추출)은 `SessionHistoryScanner` 의
/// 것을 그대로 재사용한다 — 두 벌로 갈라지면 목록과 상세가 다른 말을 하게 된다.
enum SessionTranscriptLoader {

    /// 메인 스레드에서 부르지 말 것(파일 I/O). 뷰는 `Task.detached` 로 감싼다.
    static func load(
        _ record: SessionRecord, claudeRoot: String, codexRoot: String, cursorRoot: String = ""
    ) throws -> [TranscriptTurn] {
        guard let path = resolveSource(
            record, claudeRoot: claudeRoot, codexRoot: codexRoot, cursorRoot: cursorRoot
        ) else {
            throw TranscriptError.sourceNotFound
        }

        // Cursor 는 JSONL 이 아니라 전역 state.vscdb 의 버블 행에서 대화를 복원한다.
        if record.provider == "cursor" {
            return try cursorTurns(dbPath: path, sessionId: record.sessionId)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw TranscriptError.unreadable
        }

        let turns = record.provider == "codex"
            ? codexTurns(data)
            : claudeTurns(data)
        guard !turns.isEmpty else { throw TranscriptError.empty }
        return turns
    }

    // MARK: - 원본 경로 찾기

    /// `sourcePath` 가 있으면 그대로 쓰고, 없거나(구버전 기록) 파일이 옮겨졌으면
    /// 세션 id 로 로그 루트에서 찾는다. Cursor 의 "원본" 은 전역 state.vscdb 파일이다.
    static func resolveSource(
        _ record: SessionRecord, claudeRoot: String, codexRoot: String, cursorRoot: String = ""
    ) -> String? {
        if let path = record.sourcePath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        switch record.provider {
        case "codex":
            return locateCodex(sessionId: record.sessionId, root: codexRoot)
        case "cursor":
            return CursorStateDB.resolveGlobalDB(from: cursorRoot)?.path
        default:
            return locateClaude(sessionId: record.sessionId, root: claudeRoot)
        }
    }

    /// `~/.claude/projects/<project>/<sessionId>.jsonl` — 파일명이 곧 세션 id.
    private static func locateClaude(sessionId: String, root: String) -> String? {
        guard !root.isEmpty, !sessionId.isEmpty else { return nil }
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil
        ) else { return nil }
        for project in projects {
            let candidate = project.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    /// `~/.codex/sessions/**/rollout-<timestamp>-<sessionId>.jsonl` — 파일명에 id 가 박힌다.
    private static func locateCodex(sessionId: String, root: String) -> String? {
        guard !root.isEmpty, !sessionId.isEmpty else { return nil }
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil
        ) else { return nil }
        for case let url as URL in walker
        where url.pathExtension == "jsonl"
            && url.lastPathComponent.hasPrefix("rollout-")
            && url.deletingPathExtension().lastPathComponent.hasSuffix(sessionId) {
            return url.path
        }
        return nil
    }

    // MARK: - Claude Code 트랜스크립트

    /// 사람이 친 요청과 어시스턴트 응답만 시간순으로. 서브에이전트(sidechain)와
    /// 툴 호출/결과는 대화가 아니라 실행 과정이라 제외한다.
    ///
    /// 한 응답(message.id)이 콘텐츠 블록마다 여러 줄로 쪼개져 기록되므로 같은 id 의
    /// 텍스트는 하나의 턴으로 이어 붙인다(`UsageScanner` 의 dedup 과 같은 사정).
    ///
    /// 토큰은 요청→다음 요청 사이의 assistant `message.usage` 를 (message.id,
    /// requestId) last-wins 로 dedup 해 요청 턴에 귀속한다 — `UsageScanner` 와 같은
    /// 규칙이라 일간 집계와 같은 정확도다. 본문 없는 응답(툴 호출만)과 같은 파일의
    /// sidechain 라인도 이 요청이 유발한 소비라 포함한다. 단, 별도 파일로 남는
    /// 서브에이전트 소비는 여기 안 잡혀 배지 합 < 세션 합계일 수 있다.
    private static func claudeTurns(_ data: Data) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var openAssistantID: String?
        // 요청 페어 귀속 상태 — pairIndex 는 지금까지 나온 typed 요청 수(1-based).
        // 첫 요청 전(재개 세션 선행분 등)은 0 번에 쌓이고 배지로는 쓰지 않는다.
        var pairIndex = 0
        var usageByKey: [String: TokenUsage] = [:]
        var pairByKey: [String: Int] = [:]
        var anonymous = 0

        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            let isSidechain = obj["isSidechain"] as? Bool ?? false
            let timestamp = (obj["timestamp"] as? String).flatMap(SessionHistoryScanner.parseISO)

            switch obj["type"] as? String {
            case "user":
                guard !isSidechain,
                      let promptSource = obj["promptSource"] as? String,
                      promptSource == "typed" || promptSource == "sdk",
                      let message = obj["message"] as? [String: Any],
                      let text = SessionHistoryScanner.promptText(message["content"])?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else { break }
                openAssistantID = nil  // 새 요청이 오면 직전 응답 턴은 닫는다
                pairIndex += 1
                turns.append(
                    TranscriptTurn(
                        id: turns.count, role: .user, text: text, timestamp: timestamp
                    )
                )

            case "assistant":
                // usage 수집은 본문·sidechain 여부와 무관 — 스트리밍 재등장은
                // 증가만 하므로 last-wins 로 덮고, 귀속 페어도 함께 갱신한다.
                if let message = obj["message"] as? [String: Any],
                   let u = message["usage"] as? [String: Any] {
                    let key: String
                    if let mid = message["id"] as? String, !mid.isEmpty {
                        key = mid + "|" + ((obj["requestId"] as? String) ?? "")
                    } else {
                        anonymous += 1
                        key = "__anon__\(anonymous)"
                    }
                    let input = int(u["input_tokens"])
                    let output = int(u["output_tokens"])
                    let cacheWrite = int(u["cache_creation_input_tokens"])
                    let cacheRead = int(u["cache_read_input_tokens"])
                    usageByKey[key] = TokenUsage(
                        input: input, output: output,
                        cacheRead: cacheRead, cacheWrite: cacheWrite,
                        reasoning: 0, total: input + output + cacheRead + cacheWrite
                    )
                    pairByKey[key] = pairIndex
                }
                guard !isSidechain,
                      let message = obj["message"] as? [String: Any],
                      let text = SessionHistoryScanner.assistantText(message["content"])?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else { break }
                let messageID = message["id"] as? String
                if let messageID, messageID == openAssistantID, let last = turns.last,
                   last.role == .assistant {
                    // 같은 응답의 다른 블록 — 이미 담은 문구면 버린다(줄마다 전체
                    // content 가 반복되는 형태도 있어 그대로 이으면 중복된다).
                    guard !last.text.contains(text) else { break }
                    turns[turns.count - 1] = TranscriptTurn(
                        id: last.id,
                        role: .assistant,
                        text: last.text + "\n\n" + text,
                        timestamp: last.timestamp
                    )
                } else {
                    openAssistantID = messageID
                    turns.append(
                        TranscriptTurn(
                            id: turns.count, role: .assistant, text: text, timestamp: timestamp
                        )
                    )
                }

            default:
                break
            }
        }

        var pairUsage: [Int: TokenUsage] = [:]
        for (key, usage) in usageByKey {
            guard let pair = pairByKey[key], pair > 0 else { continue }
            pairUsage[pair, default: TokenUsage()] += usage
        }
        return attach(pairUsage, to: turns)
    }

    // MARK: - Cursor 전역 state.vscdb

    /// composer 헤더 순서대로 버블을 point-lookup 해 대화를 복원한다. 본문 없는
    /// 버블(툴 스텝·컨텍스트 전용)은 대화가 아니라 실행 과정이라 제외한다 —
    /// Cursor 어시스턴트는 진행 나레이션과 최종 응답이 별개 버블로 남는데,
    /// 둘 다 사람이 읽는 텍스트라 각각의 턴으로 둔다.
    private static func cursorTurns(dbPath: String, sessionId: String) throws -> [TranscriptTurn] {
        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw TranscriptError.sourceNotFound
        }
        let turns = CursorStateDB.withDB(dbURL) { db -> [TranscriptTurn] in
            guard let composer = CursorStateDB.composer(db, id: sessionId) else { return [] }
            var out: [TranscriptTurn] = []
            for header in composer.headers where header.type == 1 || header.type == 2 {
                guard let bubble = CursorStateDB.bubble(
                    db, composerId: composer.id, bubbleId: header.bubbleId
                ), !bubble.text.isEmpty else { continue }
                out.append(
                    TranscriptTurn(
                        id: out.count,
                        role: header.type == 1 ? .user : .assistant,
                        text: bubble.text,
                        timestamp: bubble.createdAt ?? header.createdAt
                    )
                )
            }
            return out
        }
        guard let turns else { throw TranscriptError.unreadable }
        guard !turns.isEmpty else { throw TranscriptError.empty }
        return turns
    }

    // MARK: - Codex rollout

    /// 같은 요청이 `event_msg`(user_message)와 `response_item`(role=user) 양쪽에
    /// 기록되므로 직전 요청과 같은 본문이면 건너뛴다.
    ///
    /// 토큰은 `token_count` 이벤트의 **누적**(`total_token_usage`) 스냅샷을 요청
    /// 경계에서 델타로 끊어 요청 턴에 귀속한다. 턴 단건(`last_token_usage`) 합산은
    /// 중단/재시도 턴에서 누적과 어긋나는 실측 사례가 있어(`UsageScanner` 의 보정
    /// 주석 참조) 권위값인 누적을 쓴다.
    private static func codexTurns(_ data: Data) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var pairUsage: [Int: TokenUsage] = [:]
        var pairIndex = 0
        var lastCumulative = TokenUsage()
        var pairStart = TokenUsage()

        func closePair() {
            guard pairIndex > 0 else { return }
            pairUsage[pairIndex] = delta(lastCumulative, since: pairStart)
        }

        func appendUser(_ raw: String?, _ timestamp: Date?) {
            guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  SessionHistoryScanner.codexIsRealUserMessage(text)
            else { return }
            if let last = turns.last, last.role == .user, last.text == text { return }
            closePair()
            pairIndex += 1
            pairStart = lastCumulative
            turns.append(
                TranscriptTurn(id: turns.count, role: .user, text: text, timestamp: timestamp)
            )
        }

        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { continue }
            let timestamp = (obj["timestamp"] as? String).flatMap(SessionHistoryScanner.parseISO)

            switch obj["type"] as? String {
            case "event_msg":
                switch payload["type"] as? String {
                case "user_message":
                    appendUser(payload["message"] as? String, timestamp)
                case "token_count":
                    // info:null 하트비트는 스냅샷이 아니다 — 건너뛴다.
                    guard let info = payload["info"] as? [String: Any],
                          let tu = info["total_token_usage"] as? [String: Any]
                    else { break }
                    let inputTotal = int(tu["input_tokens"])     // 캐시 히트 포함
                    let cached = int(tu["cached_input_tokens"])  // input 의 부분집합
                    let output = int(tu["output_tokens"])
                    let reasoning = int(tu["reasoning_output_tokens"])
                    let total = int(tu["total_tokens"])
                    lastCumulative = TokenUsage(
                        input: max(0, inputTotal - cached), output: output,
                        cacheRead: cached, cacheWrite: 0, reasoning: reasoning,
                        total: total > 0 ? total : (inputTotal + output)
                    )
                default:
                    break
                }

            case "response_item":
                if let text = SessionHistoryScanner.codexUserMessage(from: payload) {
                    appendUser(text, timestamp)
                } else if let text = SessionHistoryScanner.codexAssistantText(from: payload)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    turns.append(
                        TranscriptTurn(
                            id: turns.count, role: .assistant, text: text, timestamp: timestamp
                        )
                    )
                }

            default:
                break
            }
        }
        closePair()
        return attach(pairUsage, to: turns)
    }

    // MARK: - 토큰 귀속 공통

    /// k 번째(1-based) 요청 턴에 pairUsage[k] 를 붙인다. 소비가 0 인 페어는 배지를
    /// 만들지 않는다(진행 중 세션에서 아직 응답 전인 마지막 요청 등).
    private static func attach(
        _ pairUsage: [Int: TokenUsage], to turns: [TranscriptTurn]
    ) -> [TranscriptTurn] {
        guard !pairUsage.isEmpty else { return turns }
        var ordinal = 0
        return turns.map { turn in
            guard turn.role == .user else { return turn }
            ordinal += 1
            guard let usage = pairUsage[ordinal], usage.total > 0 else { return turn }
            var updated = turn
            updated.usage = usage
            return updated
        }
    }

    /// 누적 스냅샷 차 — 파일 손상 등으로 역행하면 0 으로 클램프한다.
    private static func delta(_ now: TokenUsage, since base: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(0, now.input - base.input),
            output: max(0, now.output - base.output),
            cacheRead: max(0, now.cacheRead - base.cacheRead),
            cacheWrite: max(0, now.cacheWrite - base.cacheWrite),
            reasoning: max(0, now.reasoning - base.reasoning),
            total: max(0, now.total - base.total)
        )
    }

    private static func int(_ value: Any?) -> Int {
        (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0
    }
}
