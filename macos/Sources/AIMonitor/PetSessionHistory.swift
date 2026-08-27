import Foundation

/// 말풍선 히스토리의 한 턴 — 사용자 입력과 그 턴의 마지막 응답 요약.
struct PetHistoryTurn: Equatable, Identifiable {
    /// 파일 내 등장 순서(오래된 것부터) — 표시용 안정 식별자.
    let id: Int
    /// 사용자 프롬프트 첫 줄.
    let prompt: String
    /// 그 턴의 마지막 assistant 텍스트 첫 줄. 아직 응답 전이면 nil.
    var reply: String?
    let timestamp: Date?
    /// 턴의 입력 토큰 — Claude 는 마지막 assistant usage 의 input, Codex 는
    /// 세션 누적(캐시 제외)의 턴 구간 델타. 정보가 없으면 nil.
    var inputTokens: Int?
    /// 턴의 출력 토큰 — Claude 는 턴 내 assistant usage output 합,
    /// Codex 는 누적 output 의 턴 구간 델타.
    var outputTokens: Int?
}

/// 말풍선 히스토리 버튼이 눌렸을 때 세션의 지난 턴 목록을 만든다.
///
/// 라이브 폴링과 달리 사용자가 열 때 1회만 읽는다. 소스는 라이브 세션과 동일 —
/// Claude 는 훅이 기록한 트랜스크립트(JSONL), Codex 는 rollout 로그.
/// Cursor 는 로컬에 안정적인 턴 로그가 없어 히스토리를 제공하지 않는다.
enum PetSessionHistoryLoader {
    /// 꼬리 창을 단계적으로 넓힌다 — 툴 출력이 큰 세션은 마지막 사람 프롬프트가
    /// 4MB 밖에 있을 수 있다(훅 TAIL_WINDOWS 와 같은 이유). 첫 창에서 턴이
    /// 나오면 멈추고, 파일 전체를 읽었으면 더 넓히지 않는다.
    static let tailWindows = [4_194_304, 16_777_216, 67_108_864]
    /// 화면에 보여줄 최대 턴 수 — 최신 턴부터 거꾸로 센다.
    static let maxTurns = 50
    static let promptLimit = 160
    static let replyLimit = 200

    static func load(provider: String?, transcriptPath: String?) -> [PetHistoryTurn] {
        guard let transcriptPath, !transcriptPath.isEmpty else { return [] }
        for window in tailWindows {
            guard let data = ClaudeTranscriptTail.readTail(
                path: transcriptPath, bytes: window
            ) else { return [] }
            let turns: [PetHistoryTurn]
            switch provider {
            case "claude":
                turns = claudeTurns(from: data)
            case "codex":
                turns = codexTurns(from: data)
            default:
                return []
            }
            if !turns.isEmpty { return turns }
            if data.count < window { return [] }  // 파일 전체를 이미 훑었다
        }
        return []
    }

    /// Claude 트랜스크립트 JSONL — typed 사용자 프롬프트가 턴을 열고, 그 뒤의
    /// 마지막 assistant 텍스트가 응답이 된다(라이브 출력과 동일 규칙, 서브에이전트 제외).
    static func claudeTurns(from data: Data) -> [PetHistoryTurn] {
        var turns: [PetHistoryTurn] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  (obj["isSidechain"] as? Bool) != true
            else { continue }  // 꼬리 창 경계에서 잘린 첫 라인 포함
            let message = obj["message"] as? [String: Any]
            switch obj["type"] as? String {
            case "user":
                // "typed"=터미널 직접 입력, "sdk"=Paseo·cmux 같은 SDK 호스트 경유 —
                // 둘 다 사람이 낸 프롬프트다(실측: Paseo 세션은 전부 sdk).
                guard isHumanPromptSource(obj["promptSource"] as? String),
                      let text = typedUserText(message?["content"]),
                      let prompt = ClaudeTranscriptTail.firstLine(text, limit: promptLimit)
                else { continue }
                turns.append(
                    PetHistoryTurn(
                        id: turns.count,
                        prompt: prompt,
                        reply: nil,
                        timestamp: parseISO(obj["timestamp"] as? String),
                        inputTokens: nil,
                        outputTokens: nil
                    )
                )
            case "assistant":
                // 텍스트가 없는 툴 호출 턴도 usage 는 갖고 있다 — 토큰은 항상 반영.
                guard var last = turns.last else { continue }
                if let usage = message?["usage"] as? [String: Any] {
                    if let output = usage["output_tokens"] as? Int, output > 0 {
                        last.outputTokens = (last.outputTokens ?? 0) + output
                    }
                    // 프롬프트 캐시 사용 시 input_tokens 는 몇 토큰에 불과하다 —
                    // 캐시 읽기/생성분까지 합쳐야 실제 컨텍스트 크기가 된다.
                    let input = (usage["input_tokens"] as? Int ?? 0)
                        + (usage["cache_read_input_tokens"] as? Int ?? 0)
                        + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    if input > 0 {
                        last.inputTokens = input  // 마지막 호출의 컨텍스트 크기
                    }
                }
                if let text = ClaudeTranscriptTail.assistantText(message?["content"]),
                   let reply = ClaudeTranscriptTail.firstLine(text, limit: replyLimit) {
                    last.reply = reply
                }
                turns[turns.count - 1] = last
            default:
                break
            }
        }
        return Array(turns.suffix(maxTurns))
    }

    /// Codex rollout JSONL — event_msg 의 user_message 가 턴을 열고
    /// agent_message 가 응답을, token_count(세션 누적)의 턴 구간 델타가 토큰을 채운다.
    /// event_msg 가 아예 없는 구형 rollout 은 response_item 의 user/assistant
    /// message 로 폴백한다(라이브 파서의 extractUserMessage 와 같은 이유).
    static func codexTurns(from data: Data) -> [PetHistoryTurn] {
        var turns: [PetHistoryTurn] = []
        var fallbackTurns: [PetHistoryTurn] = []
        // 세션 누적값(input 은 캐시 제외 — 라이브 파서와 동일 규칙)과 턴 시작 기준점.
        var cumulativeInput = 0
        var cumulativeOutput = 0
        var baseInput = 0
        var baseOutput = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { continue }
            if obj["type"] as? String == "response_item" {
                appendCodexResponseItem(
                    payload,
                    timestamp: parseISO(obj["timestamp"] as? String),
                    to: &fallbackTurns
                )
                continue
            }
            guard obj["type"] as? String == "event_msg" else { continue }
            switch payload["type"] as? String {
            case "user_message":
                guard let text = payload["message"] as? String,
                      let prompt = ClaudeTranscriptTail.firstLine(text, limit: promptLimit)
                else { continue }
                baseInput = cumulativeInput
                baseOutput = cumulativeOutput
                turns.append(
                    PetHistoryTurn(
                        id: turns.count,
                        prompt: prompt,
                        reply: nil,
                        timestamp: parseISO(obj["timestamp"] as? String),
                        inputTokens: nil,
                        outputTokens: nil
                    )
                )
            case "agent_message":
                guard var last = turns.last,
                      let text = payload["message"] as? String,
                      let reply = ClaudeTranscriptTail.firstLine(text, limit: replyLimit)
                else { continue }
                last.reply = reply
                turns[turns.count - 1] = last
            case "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any]
                else { continue }
                let cached = total["cached_input_tokens"] as? Int ?? 0
                if let rawInput = total["input_tokens"] as? Int {
                    cumulativeInput = max(rawInput - cached, 0)
                }
                if let output = total["output_tokens"] as? Int {
                    cumulativeOutput = output
                }
                guard var last = turns.last else { continue }
                let turnInput = cumulativeInput - baseInput
                let turnOutput = cumulativeOutput - baseOutput
                last.inputTokens = turnInput > 0 ? turnInput : last.inputTokens
                last.outputTokens = turnOutput > 0 ? turnOutput : last.outputTokens
                turns[turns.count - 1] = last
            default:
                break
            }
        }
        let chosen = turns.isEmpty ? fallbackTurns : turns
        return Array(chosen.suffix(maxTurns))
    }

    /// 구형 rollout 의 response_item message — role user 의 input_text 가 턴을 열고
    /// role assistant 의 output_text 가 응답을 채운다. 토큰 정보는 없다.
    private static func appendCodexResponseItem(
        _ payload: [String: Any],
        timestamp: Date?,
        to turns: inout [PetHistoryTurn]
    ) {
        guard payload["type"] as? String == "message",
              let content = payload["content"] as? [[String: Any]]
        else { return }
        switch payload["role"] as? String {
        case "user":
            for block in content where block["type"] as? String == "input_text" {
                guard let text = block["text"] as? String,
                      isRealCodexUserMessage(text),
                      let prompt = ClaudeTranscriptTail.firstLine(text, limit: promptLimit)
                else { continue }
                turns.append(
                    PetHistoryTurn(
                        id: turns.count,
                        prompt: prompt,
                        reply: nil,
                        timestamp: timestamp,
                        inputTokens: nil,
                        outputTokens: nil
                    )
                )
                return
            }
        case "assistant":
            guard var last = turns.last else { return }
            for block in content where block["type"] as? String == "output_text" {
                guard let text = block["text"] as? String,
                      let reply = ClaudeTranscriptTail.firstLine(text, limit: replyLimit)
                else { continue }
                last.reply = reply
                turns[turns.count - 1] = last
                return
            }
        default:
            break
        }
    }

    /// 주입 컨텍스트가 아닌 실제 사용자 메시지인지 — 라이브 파서와 동일 접두어 규칙.
    private static func isRealCodexUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let skipped = [
            "# AGENTS.md instructions", "<INSTRUCTIONS>",
            "<environment_context>", "<permissions instructions>",
            "<user_instructions",
        ]
        return !skipped.contains { trimmed.hasPrefix($0) }
    }

    /// 사람이 타이핑한 프롬프트만 — tool_result 왕복 턴과 주입 텍스트는 제외
    /// (훅 extract_prompt_text 와 동일 규칙).
    private static func typedUserText(_ content: Any?) -> String? {
        if let text = content as? String {
            return isRealPrompt(text) ? text : nil
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        guard !blocks.contains(where: { $0["type"] as? String == "tool_result" })
        else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String, isRealPrompt(text) {
                return text
            }
        }
        return nil
    }

    static func isHumanPromptSource(_ source: String?) -> Bool {
        source == "typed" || source == "sdk"
    }

    static func humanPromptText(_ content: Any?) -> String? {
        typedUserText(content)
    }

    private static func isRealPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let injected = ["<command-", "<local-command", "<system-reminder",
                        "<user-prompt-submit-hook", "<task-notification"]
        return !injected.contains { trimmed.hasPrefix($0) }
    }

    private static func parseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}
