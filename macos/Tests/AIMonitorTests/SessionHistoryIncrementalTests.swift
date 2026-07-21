import Foundation
import XCTest
@testable import AIMonitor

final class SessionHistoryIncrementalTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        SessionFileCache.fileURL = tempDir.appendingPathComponent("session-files.json")
        SessionHistoryScanner.claudeBytesRead = 0
        SessionHistoryScanner.codexBytesRead = 0
    }

    override func tearDownWithError() throws {
        SessionFileCache.fileURL = AmonPaths.sessionFileCache
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCodexRolloutReadsOnlyAppendedBytesAfterInitialParse() throws {
        let rollout = tempDir.appendingPathComponent("rollout-test.jsonl")
        let initial = [
            line(type: "session_meta", payload: [
                "id": "session-1", "cwd": "/tmp/project",
            ], timestamp: "2026-07-14T01:00:00Z"),
            line(type: "turn_context", payload: [
                "cwd": "/tmp/project", "model": "gpt-5",
            ], timestamp: "2026-07-14T01:00:01Z"),
            tokenLine(total: 10, timestamp: "2026-07-14T01:00:02Z"),
        ].joined()
        try Data(initial.utf8).write(to: rollout)

        let first = SessionHistoryScanner.codexSessions(root: tempDir.path)
        let initialBytes = SessionHistoryScanner.codexBytesRead
        XCTAssertEqual(first.first?.totalTokens, 10)
        XCTAssertEqual(initialBytes, initial.utf8.count)

        _ = SessionHistoryScanner.codexSessions(root: tempDir.path)
        XCTAssertEqual(SessionHistoryScanner.codexBytesRead, initialBytes)

        let appended = tokenLine(total: 30, timestamp: "2026-07-14T01:01:00Z")
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let updated = SessionHistoryScanner.codexSessions(root: tempDir.path)
        XCTAssertEqual(updated.first?.totalTokens, 30)
        XCTAssertEqual(
            SessionHistoryScanner.codexBytesRead - initialBytes,
            appended.utf8.count
        )
    }

    func testCodexRolloutReparsesOnlyTruncatedFile() throws {
        let rollout = tempDir.appendingPathComponent("rollout-test.jsonl")
        let firstContent = [
            line(type: "session_meta", payload: ["id": "old", "cwd": "/tmp/old"]),
            tokenLine(total: 100),
        ].joined()
        try Data(firstContent.utf8).write(to: rollout)
        _ = SessionHistoryScanner.codexSessions(root: tempDir.path)

        let replacement = [
            line(type: "session_meta", payload: ["id": "new", "cwd": "/tmp/new"]),
            tokenLine(total: 7),
        ].joined()
        try Data(replacement.utf8).write(to: rollout, options: .atomic)

        let records = SessionHistoryScanner.codexSessions(root: tempDir.path)
        XCTAssertEqual(records.first?.sessionId, "new")
        XCTAssertEqual(records.first?.totalTokens, 7)
    }

    func testClaudeTranscriptUsesTheSamePersistentFileCache() throws {
        let project = tempDir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("claude-session.jsonl")
        let object: [String: Any] = [
            "timestamp": "2026-07-14T01:00:00Z",
            "cwd": "/tmp/project",
            "type": "assistant",
            "message": [
                "id": "message-1",
                "model": "claude-sonnet",
                "usage": [
                    "input_tokens": 8,
                    "output_tokens": 2,
                    "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 0,
                ],
                "content": [["type": "text", "text": "done"]],
            ],
            "requestId": "request-1",
        ]
        let lineData = try JSONSerialization.data(withJSONObject: object)
        var content = lineData
        content.append(UInt8(ascii: "\n"))
        try content.write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: transcript.path
        )

        let first = SessionHistoryScanner.claudeSessions(root: tempDir.path)
        let initialBytes = SessionHistoryScanner.claudeBytesRead
        XCTAssertEqual(first.first?.totalTokens, 10)
        XCTAssertEqual(initialBytes, content.count)

        let second = SessionHistoryScanner.claudeSessions(root: tempDir.path)
        XCTAssertEqual(second.first?.totalTokens, 10)
        XCTAssertEqual(SessionHistoryScanner.claudeBytesRead, initialBytes)
    }

    private func tokenLine(
        total: Int, timestamp: String = "2026-07-14T01:00:03Z"
    ) -> String {
        line(type: "event_msg", payload: [
            "type": "token_count",
            "info": [
                "total_token_usage": [
                    "input_tokens": total - 2,
                    "cached_input_tokens": 0,
                    "output_tokens": 2,
                    "total_tokens": total,
                ],
            ],
        ], timestamp: timestamp)
    }

    private func line(
        type: String, payload: [String: Any],
        timestamp: String = "2026-07-14T01:00:00Z"
    ) -> String {
        let object: [String: Any] = [
            "timestamp": timestamp,
            "type": type,
            "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
