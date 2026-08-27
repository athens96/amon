import Foundation

/// Claude 트랜스크립트 꼬리에서 "현재 턴의 최신 어시스턴트 출력"을 읽는다.
///
/// 훅은 턴이 끝날 때(Stop)만 `last_result` 를 기록하고 새 프롬프트 제출 때 지운다.
/// 그래서 긴 턴 동안 말풍선 출력이 직전 기록(세션 초반 내용)에 머문다. 앱은 5초
/// 폴링마다 어차피 트랜스크립트 mtime 을 읽으므로, 같은 파일 꼬리에서 최신
/// assistant 텍스트를 직접 뽑아 라이브로 덮어쓴다.
///
/// 마지막 typed 사용자 프롬프트 **이후**의 assistant 텍스트만 인정한다 — 새 턴이
/// 시작된 직후에 직전 턴의 답이 새 작업의 출력처럼 보이지 않게 한다(훅이
/// UserPromptSubmit 에서 last_result 를 지우는 규칙과 같은 의미).
enum ClaudeTranscriptTail {
    /// 훅의 첫 번째 꼬리 창과 동일 — 마지막 assistant 텍스트는 거의 항상 이 안에 있고,
    /// 없으면(툴 결과만 수백 KB) 훅이 기록한 값으로 폴백하면 된다.
    static let tailBytes = 262_144

    /// 현재 턴의 최신 assistant 텍스트 첫 줄. 새 턴 시작 후 아직 출력이 없거나
    /// 파일을 못 읽으면 nil — 호출부는 훅 기록값을 그대로 쓴다.
    static func latestOutput(transcriptPath: String?, limit: Int = 200) -> String? {
        guard let transcriptPath, !transcriptPath.isEmpty,
              let chunk = readTail(path: transcriptPath, bytes: tailBytes)
        else { return nil }
        for line in chunk.split(separator: UInt8(ascii: "\n")).reversed() {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  (obj["isSidechain"] as? Bool) != true
            else { continue }  // 창 경계에서 잘린 첫 라인·서브에이전트 라인
            switch obj["type"] as? String {
            case "assistant":
                let message = obj["message"] as? [String: Any]
                if let text = assistantText(message?["content"]) {
                    return firstLine(text, limit: limit)
                }
                // 툴만 부른 턴 — 더 이전 라인을 본다.
            case "user":
                // 역순 스캔에서 사람 프롬프트(typed·sdk)를 먼저 만났다
                // = 그 이후 출력이 아직 없다.
                if PetSessionHistoryLoader.isHumanPromptSource(
                    obj["promptSource"] as? String
                ), let message = obj["message"] as? [String: Any],
                   PetSessionHistoryLoader.humanPromptText(message["content"]) != nil {
                    return nil
                }
            default:
                break
            }
        }
        return nil
    }

    /// 어시스턴트 응답에서 사람이 읽는 텍스트만 — tool_use/thinking 블록은 건너뛴다
    /// (훅 extract_assistant_text 와 동일 규칙). 히스토리 로더도 같은 규칙을 쓴다.
    static func assistantText(_ content: Any?) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    static func firstLine(_ text: String, limit: Int) -> String? {
        guard let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespaces),
            !line.isEmpty
        else { return nil }
        return String(line.prefix(limit))
    }

    static func readTail(path: String, bytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }
}
