import Foundation
import XCTest
@testable import AIMonitor

/// 세션 상세(전체 대화) 로더 — 목록의 첫 줄 요약과 달리 **본문 전체**를 복원해야 한다.
final class SessionTranscriptTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        SessionFileCache.fileURL = tempDir.appendingPathComponent("session-files.json")
    }

    override func tearDownWithError() throws {
        SessionFileCache.fileURL = AmonPaths.sessionFileCache
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Claude

    func testClaudeTranscriptKeepsFullPromptAndAnswerInOrder() throws {
        let longAnswer = "첫 줄 요약\n둘째 줄 상세\n셋째 줄 결론"
        let file = try writeLines([
            claudeUser("배포 스크립트를 고쳐줘\n두 번째 줄도 프롬프트다", ts: "2026-07-14T01:00:00Z"),
            claudeAssistant(longAnswer, id: "msg-1", ts: "2026-07-14T01:00:05Z"),
        ], name: "session-a.jsonl")

        let turns = try SessionTranscriptLoader.load(
            record(provider: "claude", sessionId: "session-a", sourcePath: file.path),
            claudeRoot: tempDir.path, codexRoot: ""
        )

        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        // 목록은 첫 줄만 갖고 있다 — 상세는 잘리지 않은 전문이어야 한다.
        XCTAssertEqual(turns[0].text, "배포 스크립트를 고쳐줘\n두 번째 줄도 프롬프트다")
        XCTAssertEqual(turns[1].text, longAnswer)
        XCTAssertNotNil(turns[1].timestamp)
    }

    func testClaudeSplitAssistantBlocksMergeIntoOneTurn() throws {
        let file = try writeLines([
            claudeUser("질문", ts: "2026-07-14T01:00:00Z"),
            claudeAssistant("앞부분", id: "msg-1", ts: "2026-07-14T01:00:01Z"),
            claudeAssistant("뒷부분", id: "msg-1", ts: "2026-07-14T01:00:02Z"),
        ], name: "session-b.jsonl")

        let turns = try SessionTranscriptLoader.load(
            record(provider: "claude", sessionId: "session-b", sourcePath: file.path),
            claudeRoot: tempDir.path, codexRoot: ""
        )

        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns[1].text, "앞부분\n\n뒷부분")
    }

    /// 같은 message.id 라인이 같은 본문을 반복해 남기는 형태 — 이어 붙이면 중복된다.
    func testClaudeRepeatedAssistantContentIsNotDuplicated() throws {
        let file = try writeLines([
            claudeUser("질문", ts: "2026-07-14T01:00:00Z"),
            claudeAssistant("같은 답", id: "msg-1", ts: "2026-07-14T01:00:01Z"),
            claudeAssistant("같은 답", id: "msg-1", ts: "2026-07-14T01:00:02Z"),
        ], name: "session-c.jsonl")

        let turns = try SessionTranscriptLoader.load(
            record(provider: "claude", sessionId: "session-c", sourcePath: file.path),
            claudeRoot: tempDir.path, codexRoot: ""
        )
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].text, "같은 답")
    }

    func testClaudeExcludesSidechainAndInjectedPrompts() throws {
        let file = try writeLines([
            claudeUser("진짜 요청", ts: "2026-07-14T01:00:00Z"),
            claudeUser("훅이 넣은 것", ts: "2026-07-14T01:00:01Z", promptSource: "system"),
            claudeAssistant("서브에이전트 응답", id: "msg-9", ts: "2026-07-14T01:00:02Z", sidechain: true),
            claudeAssistant("본 세션 응답", id: "msg-1", ts: "2026-07-14T01:00:03Z"),
        ], name: "session-d.jsonl")

        let turns = try SessionTranscriptLoader.load(
            record(provider: "claude", sessionId: "session-d", sourcePath: file.path),
            claudeRoot: tempDir.path, codexRoot: ""
        )
        XCTAssertEqual(turns.map(\.text), ["진짜 요청", "본 세션 응답"])
    }

    /// 요청→다음 요청 사이의 usage 를 요청 턴에 귀속 — 스트리밍 재등장은 last-wins,
    /// 본문 없는 툴 스텝과 같은 파일의 sidechain 소비도 페어에 포함된다.
    func testClaudeTurnUsageAttributedToRequestPair() throws {
        let file = try writeLines([
            claudeUser("첫 요청", ts: "2026-07-14T01:00:00Z"),
            claudeAssistant(
                "답 1", id: "msg-1", ts: "2026-07-14T01:00:01Z",
                usage: ["input_tokens": 50, "output_tokens": 5, "cache_read_input_tokens": 100]
            ),
            // 같은 (message.id, requestId) 재등장 — 마지막 값만 반영돼야 한다.
            claudeAssistant(
                "답 1", id: "msg-1", ts: "2026-07-14T01:00:02Z",
                usage: [
                    "input_tokens": 100, "output_tokens": 10,
                    "cache_read_input_tokens": 200, "cache_creation_input_tokens": 30,
                ]
            ),
            claudeToolStep(
                id: "msg-2", ts: "2026-07-14T01:00:03Z",
                usage: ["input_tokens": 7, "output_tokens": 3]
            ),
            claudeAssistant(
                "서브에이전트 응답", id: "msg-3", ts: "2026-07-14T01:00:04Z", sidechain: true,
                usage: ["input_tokens": 4, "output_tokens": 1]
            ),
            claudeUser("둘째 요청", ts: "2026-07-14T01:01:00Z"),
            claudeAssistant(
                "답 2", id: "msg-4", ts: "2026-07-14T01:01:01Z",
                usage: ["input_tokens": 20, "output_tokens": 2]
            ),
        ], name: "session-u.jsonl")

        let turns = try SessionTranscriptLoader.load(
            record(provider: "claude", sessionId: "session-u", sourcePath: file.path),
            claudeRoot: tempDir.path, codexRoot: ""
        )

        // 표시 턴은 그대로: 툴 스텝·sidechain 은 대화에 안 보인다.
        XCTAssertEqual(turns.map(\.role), [.user, .assistant, .user, .assistant])
        let first = try XCTUnwrap(turns[0].usage)
        XCTAssertEqual(first.input, 100 + 7 + 4)
        XCTAssertEqual(first.output, 10 + 3 + 1)
        XCTAssertEqual(first.cacheRead, 200)
        XCTAssertEqual(first.cacheWrite, 30)
        XCTAssertEqual(first.total, 355)
        let second = try XCTUnwrap(turns[2].usage)
        XCTAssertEqual(second.total, 22)
        // 배지는 요청 턴에만 붙는다.
        XCTAssertNil(turns[1].usage)
        XCTAssertNil(turns[3].usage)
    }

    // MARK: - Codex

    func testCodexTranscriptDedupesUserMessageRecordedTwice() throws {
        let file = try writeLines([
            codexEventUser("리팩터링 해줘", ts: "2026-07-14T02:00:00Z"),
            codexResponseUser("리팩터링 해줘", ts: "2026-07-14T02:00:00Z"),
            codexResponseAssistant("전체 응답\n두 번째 줄", ts: "2026-07-14T02:00:10Z"),
        ], name: "rollout-2026-07-14T02-00-00-session-x.jsonl")

        let turns = try SessionTranscriptLoader.load(
            record(provider: "codex", sessionId: "session-x", sourcePath: file.path),
            claudeRoot: "", codexRoot: tempDir.path
        )

        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns[0].text, "리팩터링 해줘")
        XCTAssertEqual(turns[1].text, "전체 응답\n두 번째 줄")
    }

    /// 누적(total_token_usage) 스냅샷의 요청 경계 델타가 각 요청 턴에 귀속된다.
    func testCodexTurnUsageFromCumulativeSnapshots() throws {
        let file = try writeLines([
            codexEventUser("첫 요청", ts: "2026-07-14T02:00:00Z"),
            codexResponseAssistant("응답 1", ts: "2026-07-14T02:00:05Z"),
            codexTokenCount(
                ts: "2026-07-14T02:00:06Z",
                input: 1000, cached: 400, output: 50, reasoning: 10, total: 1050
            ),
            codexEventUser("둘째 요청", ts: "2026-07-14T02:01:00Z"),
            codexResponseAssistant("응답 2", ts: "2026-07-14T02:01:05Z"),
            codexTokenCount(
                ts: "2026-07-14T02:01:06Z",
                input: 2000, cached: 900, output: 120, reasoning: 25, total: 2120
            ),
        ], name: "rollout-2026-07-14T02-00-00-session-y.jsonl")

        let turns = try SessionTranscriptLoader.load(
            record(provider: "codex", sessionId: "session-y", sourcePath: file.path),
            claudeRoot: "", codexRoot: tempDir.path
        )

        XCTAssertEqual(turns.map(\.role), [.user, .assistant, .user, .assistant])
        let first = try XCTUnwrap(turns[0].usage)
        XCTAssertEqual(first.input, 600)  // input_tokens 는 캐시 히트 포함 — 분리 저장
        XCTAssertEqual(first.cacheRead, 400)
        XCTAssertEqual(first.output, 50)
        XCTAssertEqual(first.reasoning, 10)
        XCTAssertEqual(first.total, 1050)
        let second = try XCTUnwrap(turns[2].usage)
        XCTAssertEqual(second.input, 500)  // (2000-900) - (1000-400)
        XCTAssertEqual(second.cacheRead, 500)
        XCTAssertEqual(second.output, 70)
        XCTAssertEqual(second.reasoning, 15)
        XCTAssertEqual(second.total, 1070)
        XCTAssertNil(turns[1].usage)
        XCTAssertNil(turns[3].usage)
    }

    // MARK: - 원본 경로 해석

    func testSourcePathIsRecordedByScannerForLocalTranscript() throws {
        let projectDir = tempDir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("session-e.jsonl")
        try Data(([
            claudeUser("요청", ts: "2020-01-01T00:00:00Z"),
            claudeAssistant("응답", id: "msg-1", ts: "2020-01-01T00:00:01Z", tokens: 12),
        ].joined()).utf8).write(to: transcript)
        // 방금 수정된 트랜스크립트는 아직 진행 중일 수 있어 스캐너가 건너뛴다(activeGrace).
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: transcript.path
        )

        let records = SessionHistoryScanner.claudeSessions(root: tempDir.path)
        let scanned = try XCTUnwrap(records.first { $0.sessionId == "session-e" })
        // /var → /private/var 심볼릭 링크 차이를 흡수한다.
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(scanned.sourcePath)).resolvingSymlinksInPath(),
            transcript.resolvingSymlinksInPath()
        )
    }

    /// 구버전 기록(sourcePath 없음)도 세션 id 로 원본을 찾아낸다.
    func testLocatesClaudeSourceBySessionIdWhenPathMissing() throws {
        let projectDir = tempDir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("session-f.jsonl")
        try Data(([
            claudeUser("요청", ts: "2026-07-14T01:00:00Z"),
            claudeAssistant("응답 전문", id: "msg-1", ts: "2026-07-14T01:00:01Z"),
        ].joined()).utf8).write(to: transcript)

        let turns = try SessionTranscriptLoader.load(
            record(provider: "claude", sessionId: "session-f", sourcePath: nil),
            claudeRoot: tempDir.path, codexRoot: ""
        )
        XCTAssertEqual(turns.map(\.text), ["요청", "응답 전문"])
    }

    func testMissingSourceThrows() {
        XCTAssertThrowsError(
            try SessionTranscriptLoader.load(
                record(provider: "claude", sessionId: "없는세션", sourcePath: "/nope/none.jsonl"),
                claudeRoot: tempDir.path, codexRoot: ""
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptError, .sourceNotFound)
        }
    }

    // MARK: - fixtures

    private func writeLines(_ lines: [String], name: String) throws -> URL {
        let file = tempDir.appendingPathComponent(name)
        try Data(lines.joined().utf8).write(to: file)
        return file
    }

    private func record(
        provider: String, sessionId: String, sourcePath: String?
    ) -> SessionRecord {
        SessionRecord(
            provider: provider, sessionId: sessionId, projectLabel: "p", gitBranch: nil,
            startedAt: Date(), endedAt: Date(), prompts: [], promptCount: 0,
            currentTask: nil, lastResult: nil, inputTokens: 0, outputTokens: 0,
            cacheTokens: 0, totalTokens: 0, models: [:], agentCount: 0,
            sourcePath: sourcePath
        )
    }

    private func json(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    private func claudeUser(
        _ text: String, ts: String, promptSource: String = "typed"
    ) -> String {
        json([
            "type": "user", "timestamp": ts, "promptSource": promptSource,
            "cwd": "/tmp/project",
            "message": ["content": [["type": "text", "text": text]]],
        ])
    }

    private func claudeAssistant(
        _ text: String, id: String, ts: String, sidechain: Bool = false, tokens: Int = 0,
        usage: [String: Int]? = nil
    ) -> String {
        var message: [String: Any] = [
            "id": id, "model": "claude-opus-4-8",
            "content": [["type": "text", "text": text]],
        ]
        if let usage {
            message["usage"] = usage
        } else if tokens > 0 {
            message["usage"] = ["input_tokens": tokens, "output_tokens": tokens]
        }
        return json([
            "type": "assistant", "timestamp": ts, "isSidechain": sidechain,
            "requestId": "req-\(id)", "message": message,
        ])
    }

    /// 본문 없는 응답 라인(툴 호출만) — 대화 턴은 안 만들지만 usage 는 남는다.
    private func claudeToolStep(id: String, ts: String, usage: [String: Int]) -> String {
        json([
            "type": "assistant", "timestamp": ts,
            "requestId": "req-\(id)",
            "message": [
                "id": id, "model": "claude-opus-4-8",
                "content": [["type": "tool_use", "name": "Bash", "input": [:]]],
                "usage": usage,
            ],
        ])
    }

    private func codexEventUser(_ text: String, ts: String) -> String {
        json([
            "type": "event_msg", "timestamp": ts,
            "payload": ["type": "user_message", "message": text],
        ])
    }

    private func codexResponseUser(_ text: String, ts: String) -> String {
        json([
            "type": "response_item", "timestamp": ts,
            "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ])
    }

    /// token_count 이벤트 — total_token_usage 는 세션 **누적** 스냅샷.
    private func codexTokenCount(
        ts: String, input: Int, cached: Int, output: Int, reasoning: Int, total: Int
    ) -> String {
        json([
            "type": "event_msg", "timestamp": ts,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input, "cached_input_tokens": cached,
                        "output_tokens": output, "reasoning_output_tokens": reasoning,
                        "total_tokens": total,
                    ],
                ],
            ],
        ])
    }

    private func codexResponseAssistant(_ text: String, ts: String) -> String {
        json([
            "type": "response_item", "timestamp": ts,
            "payload": [
                "type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": text]],
            ],
        ])
    }
}
