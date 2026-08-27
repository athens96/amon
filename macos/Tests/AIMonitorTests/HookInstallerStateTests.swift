import Foundation
import XCTest

@testable import AIMonitor

final class HookInstallerStateTests: XCTestCase {
    private var tempHome: URL!
    private var scriptURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("amon-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempHome,
            withIntermediateDirectories: true
        )
        scriptURL = tempHome.appendingPathComponent("live_hook.py")
        try HookInstaller.hookScriptSourceForTesting.write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        try super.tearDownWithError()
    }

    func testInstallerRegistersOnlyStructuredAttentionSignals() {
        let events = Set(HookInstaller.configuredEventsForTesting)

        XCTAssertTrue(events.isSuperset(of: [
            "Notification", "PermissionRequest", "PermissionDenied",
            "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "Elicitation", "ElicitationResult",
        ]))
        XCTAssertEqual(
            Set(HookInstaller.notificationMatcherForTesting.split(separator: "|").map(String.init)),
            [
                "permission_prompt", "idle_prompt", "elicitation_dialog",
                "elicitation_complete", "elicitation_response",
            ]
        )
        XCTAssertFalse(HookInstaller.notificationMatcherForTesting.contains("auth_success"))
        XCTAssertEqual(HookInstaller.preToolMatcherForTesting, "Agent|Task|AskUserQuestion")
    }

    func testNotificationTypeDrivesStateWithoutInspectingMessageText() throws {
        _ = try send([
            "hook_event_name": "SessionStart", "session_id": "notification", "cwd": tempHome.path,
        ])

        var state = try send([
            "hook_event_name": "Notification", "session_id": "notification", "cwd": tempHome.path,
            "notification_type": "auth_success",
            "message": "Claude needs your permission to use Bash",
        ])
        XCTAssertEqual(state["status"] as? String, "active")
        XCTAssertNil(state["notice"] as? String)

        state = try send([
            "hook_event_name": "Notification", "session_id": "notification", "cwd": tempHome.path,
            "notification_type": "permission_prompt",
            "message": "언어와 무관한 표시 문구",
        ])
        XCTAssertEqual(state["status"] as? String, "needs_input")
        XCTAssertEqual(state["attention_kind"] as? String, "permission")
        XCTAssertEqual(state["notice"] as? String, "언어와 무관한 표시 문구")

        state = try send([
            "hook_event_name": "Notification", "session_id": "notification", "cwd": tempHome.path,
            "notification_type": "idle_prompt",
            "message": "Claude is waiting for your input",
        ])
        XCTAssertEqual(state["status"] as? String, "idle")
        XCTAssertNil(state["attention_kind"] as? String)
        XCTAssertNil(state["notice"] as? String)

        state = try send([
            "hook_event_name": "Notification", "session_id": "notification", "cwd": tempHome.path,
            "notification_type": "elicitation_complete",
            "message": "완료",
        ])
        XCTAssertEqual(state["status"] as? String, "active")
        XCTAssertNil(state["attention_kind"] as? String)
    }

    func testAskUserQuestionIsWaitingButNeverRecordedAsAgent() throws {
        _ = try send([
            "hook_event_name": "SessionStart", "session_id": "question", "cwd": tempHome.path,
        ])
        var state = try send([
            "hook_event_name": "PreToolUse", "session_id": "question", "cwd": tempHome.path,
            "tool_name": "AskUserQuestion", "tool_use_id": "question-1",
            "tool_input": [
                "questions": [["question": "PRIVATE QUESTION TEXT", "header": "선택"]],
            ],
        ])

        XCTAssertEqual(state["status"] as? String, "needs_input")
        XCTAssertEqual(state["attention_kind"] as? String, "question")
        XCTAssertEqual((state["agents"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((state["agent_total"] as? NSNumber)?.intValue, 0)
        XCTAssertFalse(try stateJSON(sessionID: "question").contains("PRIVATE QUESTION TEXT"))

        state = try send([
            "hook_event_name": "PostToolUse", "session_id": "question", "cwd": tempHome.path,
            "tool_name": "AskUserQuestion", "tool_use_id": "question-1",
            "tool_response": ["answers": ["PRIVATE QUESTION TEXT": "A"]],
        ])
        XCTAssertEqual(state["status"] as? String, "active")
        XCTAssertNil(state["attention_kind"] as? String)
        XCTAssertEqual((state["agents"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse(try stateJSON(sessionID: "question").contains("PRIVATE QUESTION TEXT"))
    }

    func testPermissionRequestAndToolCompletionFormAPairedTransition() throws {
        _ = try send([
            "hook_event_name": "SessionStart", "session_id": "permission", "cwd": tempHome.path,
        ])
        var state = try send([
            "hook_event_name": "PermissionRequest", "session_id": "permission", "cwd": tempHome.path,
            "tool_name": "Bash",
            "tool_input": ["command": "PRIVATE COMMAND TEXT"],
        ])

        XCTAssertEqual(state["status"] as? String, "needs_input")
        XCTAssertEqual(state["attention_kind"] as? String, "permission")
        XCTAssertEqual(state["notice"] as? String, "Bash 권한 확인이 필요합니다")
        XCTAssertFalse(try stateJSON(sessionID: "permission").contains("PRIVATE COMMAND TEXT"))

        state = try send([
            "hook_event_name": "PostToolUse", "session_id": "permission", "cwd": tempHome.path,
            "tool_name": "Bash", "tool_use_id": "bash-1",
            "tool_response": ["stdout": "PRIVATE TOOL OUTPUT"],
        ])
        XCTAssertEqual(state["status"] as? String, "active")
        XCTAssertNil(state["attention_kind"] as? String)
        XCTAssertNil(state["notice"] as? String)
        XCTAssertFalse(try stateJSON(sessionID: "permission").contains("PRIVATE TOOL OUTPUT"))
    }

    func testElicitationAndResultUseStructuredPairedEvents() throws {
        _ = try send([
            "hook_event_name": "SessionStart", "session_id": "elicitation", "cwd": tempHome.path,
        ])
        var state = try send([
            "hook_event_name": "Elicitation", "session_id": "elicitation", "cwd": tempHome.path,
            "mcp_server_name": "example", "message": "계정 값을 입력해 주세요",
            "requested_schema": ["secret": "PRIVATE SCHEMA TEXT"],
        ])
        XCTAssertEqual(state["status"] as? String, "needs_input")
        XCTAssertEqual(state["attention_kind"] as? String, "elicitation")
        XCTAssertEqual(state["notice"] as? String, "계정 값을 입력해 주세요")
        XCTAssertFalse(try stateJSON(sessionID: "elicitation").contains("PRIVATE SCHEMA TEXT"))

        state = try send([
            "hook_event_name": "ElicitationResult", "session_id": "elicitation", "cwd": tempHome.path,
            "mcp_server_name": "example", "action": "accept",
            "content": ["secret": "PRIVATE ANSWER TEXT"],
        ])
        XCTAssertEqual(state["status"] as? String, "active")
        XCTAssertNil(state["attention_kind"] as? String)
        XCTAssertNil(state["notice"] as? String)
        XCTAssertFalse(try stateJSON(sessionID: "elicitation").contains("PRIVATE ANSWER TEXT"))
    }

    func testConcurrentAgentStartsDoNotLoseWholeFileUpdates() throws {
        _ = try send([
            "hook_event_name": "SessionStart", "session_id": "concurrent", "cwd": tempHome.path,
        ])

        let count = 12
        let queue = DispatchQueue(label: "amon-hook-tests", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [String] = []
        for index in 0..<count {
            group.enter()
            queue.async { [self] in
                defer { group.leave() }
                do {
                    _ = try run([
                        "hook_event_name": "PreToolUse", "session_id": "concurrent",
                        "cwd": tempHome.path, "tool_name": "Agent",
                        "tool_use_id": "agent-\(index)",
                        "tool_input": ["description": "agent \(index)", "subagent_type": "Explore"],
                    ])
                } catch {
                    lock.lock()
                    failures.append(error.localizedDescription)
                    lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))

        let state = try readState(sessionID: "concurrent")
        XCTAssertEqual((state["agents"] as? [[String: Any]])?.count, count)
        XCTAssertEqual((state["agent_total"] as? NSNumber)?.intValue, count)
    }

    @discardableResult
    private func send(_ payload: [String: Any]) throws -> [String: Any] {
        _ = try run(payload)
        guard let sessionID = payload["session_id"] as? String else {
            throw TestError.missingSessionID
        }
        return try readState(sessionID: sessionID)
    }

    private func run(_ payload: [String: Any]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempHome.path
        process.environment = environment

        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        try process.run()
        let data = try JSONSerialization.data(withJSONObject: payload)
        input.fileHandleForWriting.write(data)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw TestError.processFailed(process.terminationStatus, message)
        }
        return process.terminationStatus
    }

    private func readState(sessionID: String) throws -> [String: Any] {
        let data = try Data(contentsOf: stateURL(sessionID: sessionID))
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError.invalidState
        }
        return state
    }

    private func stateJSON(sessionID: String) throws -> String {
        String(data: try Data(contentsOf: stateURL(sessionID: sessionID)), encoding: .utf8) ?? ""
    }

    private func stateURL(sessionID: String) -> URL {
        tempHome
            .appendingPathComponent("Library/Application Support/A-mon/live", isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
    }

    private enum TestError: Error {
        case missingSessionID
        case invalidState
        case processFailed(Int32, String)
    }
}
