import Foundation
import XCTest
@testable import AIMonitor

/// 훅은 턴 시작·종료와 서브에이전트 호출에만 세션 파일을 건드린다. 그래서 서브에이전트
/// 없이 툴만 오래 쓰는 턴에서는 갱신이 한 번도 없어, 멀쩡히 돌아가는 세션이 15분 stale
/// 규칙에 걸려 펫에서 사라졌다. 트랜스크립트는 턴 내내 append 되므로 그 mtime 을
/// 생존 판정에 함께 본다.
final class LiveSessionLivenessTests: XCTestCase {
    func testLongToolOnlyTurnSurvivesWhenTranscriptIsStillGrowing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // 훅 기록은 40분 전이 마지막 — 그것만 보면 stale 이다.
        let transcript = try writeTranscript(in: root, modified: Date())
        try writeSession(
            in: root,
            id: "long-turn",
            updatedAt: Date().addingTimeInterval(-40 * 60),
            transcriptPath: transcript.path
        )

        let sessions = load(root)

        XCTAssertEqual(sessions.count, 1, "트랜스크립트가 계속 자라면 살아 있는 세션이다")
        XCTAssertEqual(sessions.first?.sessionId, "long-turn")
    }

    func testUpdatedAtReflectsTranscriptActivity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let touched = Date().addingTimeInterval(-30)
        let transcript = try writeTranscript(in: root, modified: touched)
        try writeSession(
            in: root,
            id: "long-turn",
            updatedAt: Date().addingTimeInterval(-40 * 60),
            transcriptPath: transcript.path
        )

        let session = try XCTUnwrap(load(root).first)

        // 훅 기록이 아니라 실제 활동 시각이 보여야 "몇 분째 작업 중" 이 맞는다.
        XCTAssertEqual(session.updatedAt.timeIntervalSince1970, touched.timeIntervalSince1970, accuracy: 2)
    }

    func testDeadSessionIsStillDroppedWhenTranscriptIsAlsoStale() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // 크래시/좀비 세션 — 훅도 트랜스크립트도 오래 전에 멈췄다.
        let old = Date().addingTimeInterval(-40 * 60)
        let transcript = try writeTranscript(in: root, modified: old)
        try writeSession(in: root, id: "zombie", updatedAt: old, transcriptPath: transcript.path)

        XCTAssertTrue(load(root).isEmpty)
    }

    func testMissingTranscriptFallsBackToHookTimestamp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // 트랜스크립트 경로가 없거나 파일이 지워졌으면 기존 판정 그대로다.
        try writeSession(in: root, id: "fresh", updatedAt: Date(), transcriptPath: nil)
        try writeSession(
            in: root,
            id: "gone",
            updatedAt: Date().addingTimeInterval(-40 * 60),
            transcriptPath: root.appendingPathComponent("does-not-exist.jsonl").path
        )

        let sessions = load(root)

        XCTAssertEqual(sessions.map(\.sessionId), ["fresh"])
    }

    func testNoticeIsDecodedForWaitingSessions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSession(
            in: root,
            id: "waiting",
            updatedAt: Date(),
            transcriptPath: nil,
            status: "needs_input",
            notice: "Claude needs your permission to use Bash"
        )

        let session = try XCTUnwrap(load(root).first)

        XCTAssertEqual(session.status, "needs_input")
        XCTAssertEqual(session.notice, "Claude needs your permission to use Bash")
    }

    // MARK: - 헬퍼

    /// Codex/Cursor 경로는 비워 Claude 훅 디렉토리만 검사한다.
    private func load(_ root: URL) -> [LiveSession] {
        LiveSessionParser.load(
            from: root.appendingPathComponent("live", isDirectory: true),
            codexRoot: root.appendingPathComponent("no-codex").path,
            cursorPath: root.appendingPathComponent("no-cursor.vscdb").path
        )
    }

    private func writeSession(
        in root: URL,
        id: String,
        updatedAt: Date,
        transcriptPath: String?,
        status: String = "active",
        notice: String? = nil
    ) throws {
        let dir = root.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        var payload: [String: Any] = [
            "provider": "claude",
            "session_id": id,
            "project_label": "amon-dev",
            "status": status,
            "agents": [],
            "current_task": "펫 UI 구현",
            "started_at": stamp.string(from: updatedAt.addingTimeInterval(-3600)),
            "updated_at": stamp.string(from: updatedAt),
        ]
        payload["transcript_path"] = transcriptPath
        payload["notice"] = notice

        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    private func writeTranscript(in root: URL, modified: Date) throws -> URL {
        let url = root.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amon-liveness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
