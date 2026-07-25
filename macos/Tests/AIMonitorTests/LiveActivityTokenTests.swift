import Foundation
import XCTest
@testable import AIMonitor

final class LiveActivityTokenTests: XCTestCase {
    func testCodexRolloutCapturesInputOutputAndBoundedAssistantPreview() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let longOutput = String(repeating: "출", count: 240) + "\n저장하면 안 되는 둘째 줄"
        let records: [[String: Any]] = [
            [
                "timestamp": now,
                "type": "session_meta",
                "payload": ["id": "codex-live-1", "cwd": "/tmp/amon-project"],
            ],
            [
                "timestamp": now,
                "type": "event_msg",
                "payload": ["type": "user_message", "message": "입력 요청 첫 줄\n둘째 줄"],
            ],
            [
                "timestamp": now,
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": longOutput]],
                ],
            ],
            [
                "timestamp": now,
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 1_234,
                            "output_tokens": 567,
                            "total_tokens": 1_801,
                        ],
                    ],
                ],
            ],
        ]
        try writeJSONLines(records, to: root.appendingPathComponent("rollout-test.jsonl"))

        let session = try XCTUnwrap(CodexLiveParser.load(from: root.path).first)
        XCTAssertEqual(session.currentTask, "입력 요청 첫 줄")
        XCTAssertEqual(session.lastResult, String(repeating: "출", count: 200))
        XCTAssertEqual(session.inputTokens, 1_234)
        XCTAssertEqual(session.outputTokens, 567)
        XCTAssertEqual(session.totalTokens, 1_801)
    }

    func testCodexRolloutUsesLatestTurnAndAcceptsSafeTextVariant() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let records: [[String: Any]] = [
            [
                "timestamp": now,
                "type": "session_meta",
                "payload": ["id": "codex-live-2", "cwd": "/tmp/amon-project"],
            ],
            [
                "timestamp": now,
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "첫 요청"]],
                ],
            ],
            [
                "timestamp": now,
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "text", "text": "첫 응답"]],
                ],
            ],
            [
                "timestamp": now,
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "text", "text": "둘째 요청"]],
                ],
            ],
            [
                "timestamp": now,
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 6,
                            "output_tokens": 4,
                        ],
                    ],
                ],
            ],
        ]
        try writeJSONLines(records, to: root.appendingPathComponent("rollout-test.jsonl"))

        let session = try XCTUnwrap(CodexLiveParser.load(from: root.path).first)
        XCTAssertEqual(session.currentTask, "둘째 요청")
        XCTAssertNil(session.lastResult)
        XCTAssertEqual(session.inputTokens, 14)
        XCTAssertEqual(session.outputTokens, 4)
        XCTAssertEqual(session.totalTokens, 24)
    }

    func testCodexAssistantAcceptsSafeTopLevelMessageVariant() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let records: [[String: Any]] = [
            [
                "timestamp": now,
                "type": "session_meta",
                "payload": ["id": "codex-live-3", "cwd": "/tmp/amon-project"],
            ],
            [
                "timestamp": now,
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "message": "안전한 응답 미리보기\n둘째 줄",
                ],
            ],
        ]
        try writeJSONLines(records, to: root.appendingPathComponent("rollout-test.jsonl"))

        let session = try XCTUnwrap(CodexLiveParser.load(from: root.path).first)
        XCTAssertEqual(session.lastResult, "안전한 응답 미리보기")
    }

    func testCodexInternalJSONEventDoesNotReplaceAssistantPreview() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let records: [[String: Any]] = [
            [
                "timestamp": now,
                "type": "session_meta",
                "payload": ["id": "codex-live-json", "cwd": "/tmp/amon-project"],
            ],
            [
                "timestamp": now,
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "사용자에게 보여 줄 응답"]],
                ],
            ],
            [
                "timestamp": now,
                "type": "event_msg",
                "payload": [
                    "type": "agent_message",
                    "message": "{\n\"Outcome\":\"allow\"\n}",
                ],
            ],
        ]
        try writeJSONLines(records, to: root.appendingPathComponent("rollout-test.jsonl"))

        let session = try XCTUnwrap(CodexLiveParser.load(from: root.path).first)
        XCTAssertEqual(session.lastResult, "사용자에게 보여 줄 응답")
    }

    func testCodexCompletedTaskIsNotReportedAsActiveFromRecentMtime() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let records: [[String: Any]] = [
            [
                "timestamp": now,
                "type": "session_meta",
                "payload": ["id": "codex-complete", "cwd": "/tmp/amon-project"],
            ],
            [
                "timestamp": now,
                "type": "event_msg",
                "payload": ["type": "task_started", "turn_id": "turn-1"],
            ],
            [
                "timestamp": now,
                "type": "event_msg",
                "payload": ["type": "task_complete", "turn_id": "turn-1"],
            ],
        ]
        try writeJSONLines(records, to: root.appendingPathComponent("rollout-test.jsonl"))

        let session = try XCTUnwrap(CodexLiveParser.load(from: root.path).first)
        XCTAssertEqual(session.status, "idle")
    }

    func testCodexOpenTaskIsReportedAsActive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let records: [[String: Any]] = [
            [
                "timestamp": now,
                "type": "session_meta",
                "payload": ["id": "codex-active", "cwd": "/tmp/amon-project"],
            ],
            [
                "timestamp": now,
                "type": "event_msg",
                "payload": ["type": "task_started", "turn_id": "turn-1"],
            ],
        ]
        try writeJSONLines(records, to: root.appendingPathComponent("rollout-test.jsonl"))

        let session = try XCTUnwrap(CodexLiveParser.load(from: root.path).first)
        XCTAssertEqual(session.status, "active")
    }

    func testClaudeLiveDTOWithoutTokenBreakdownRemainsBackwardCompatible() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let legacy: [String: Any] = [
            "session_id": "legacy",
            "project_label": "old-project",
            "status": "idle",
            "agents": [],
            "current_task": "기존 요청",
            "last_result": "기존 응답",
            "total_tokens": 99,
            "started_at": now,
            "updated_at": now,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: root.appendingPathComponent("legacy.json"))

        let session = try XCTUnwrap(
            LiveSessionParser.load(from: root, codexRoot: "", cursorPath: "").first
        )
        XCTAssertEqual(session.provider, "claude")
        XCTAssertEqual(session.totalTokens, 99)
        XCTAssertNil(session.inputTokens)
        XCTAssertNil(session.outputTokens)
    }

    func testClaudeLiveDTOReadsOptionalTokenBreakdown() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let snapshot: [String: Any] = [
            "provider": "claude",
            "session_id": "new",
            "project_label": "new-project",
            "status": "active",
            "agents": [],
            "current_task": "요청",
            "last_result": "응답",
            "model": "claude-test",
            "total_tokens": 42,
            "input_tokens": 30,
            "output_tokens": 12,
            "started_at": now,
            "updated_at": now,
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        try data.write(to: root.appendingPathComponent("new.json"))

        let session = try XCTUnwrap(
            LiveSessionParser.load(from: root, codexRoot: "", cursorPath: "").first
        )
        XCTAssertEqual(session.inputTokens, 30)
        XCTAssertEqual(session.outputTokens, 12)
        XCTAssertEqual(session.lastResult, "응답")
    }

    func testClaudeHookStoresLatestUsageAndOnlyBoundedAssistantFirstLine() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let transcript = home.appendingPathComponent("transcript.jsonl")
        let longOutput = String(repeating: "답", count: 240) + "\n저장하면 안 되는 둘째 줄"
        let assistant: [String: Any] = [
            "type": "assistant",
            "message": [
                "model": "claude-test",
                "content": [["type": "text", "text": longOutput]],
                "usage": [
                    "input_tokens": 101,
                    "output_tokens": 23,
                    "cache_read_input_tokens": 7,
                    "cache_creation_input_tokens": 5,
                ],
            ],
        ]
        try writeJSONLines([assistant], to: transcript)

        let script = home.appendingPathComponent("live_hook.py")
        try HookInstaller.hookScriptSource.write(to: script, atomically: true, encoding: .utf8)
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "hook-live-1",
            "cwd": home.path,
            "transcript_path": transcript.path,
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let live = home.appendingPathComponent(
            "Library/Application Support/A-mon/live/hook-live-1.json"
        )
        let resultData = try Data(contentsOf: live)
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        )
        XCTAssertEqual(result["model"] as? String, "claude-test")
        XCTAssertEqual(result["input_tokens"] as? Int, 101)
        XCTAssertEqual(result["output_tokens"] as? Int, 23)
        XCTAssertEqual(result["total_tokens"] as? Int, 136)
        XCTAssertEqual(result["last_result"] as? String, String(repeating: "답", count: 200))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amon-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSONLines(_ values: [[String: Any]], to url: URL) throws {
        let lines = try values.map {
            String(
                decoding: try JSONSerialization.data(withJSONObject: $0),
                as: UTF8.self
            )
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }
}
