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

    // MARK: - 원본 경로 해석

    func testSourcePathIsRecordedByScannerAndStrippedFromServerPayload() throws {
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

        // 서버 페이로드에는 로컬 경로가 실리면 안 된다.
        var reported = scanned
        reported.sourcePath = nil
        let json = try XCTUnwrap(
            String(data: try AmonJSON.encoder().encode(reported), encoding: .utf8)
        )
        XCTAssertFalse(json.contains("source_path"))
        XCTAssertFalse(json.contains(transcript.path))
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
        _ text: String, id: String, ts: String, sidechain: Bool = false, tokens: Int = 0
    ) -> String {
        var message: [String: Any] = [
            "id": id, "model": "claude-opus-4-8",
            "content": [["type": "text", "text": text]],
        ]
        if tokens > 0 {
            message["usage"] = ["input_tokens": tokens, "output_tokens": tokens]
        }
        return json([
            "type": "assistant", "timestamp": ts, "isSidechain": sidechain,
            "requestId": "req-\(id)", "message": message,
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
