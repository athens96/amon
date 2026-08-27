import XCTest
@testable import AIMonitor

final class ClaudeTranscriptTailTests: XCTestCase {
    private var tempFile: URL!

    override func setUpWithError() throws {
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFile)
    }

    private func write(_ lines: [String]) throws {
        try lines.joined(separator: "\n").write(
            to: tempFile, atomically: true, encoding: .utf8
        )
    }

    private func assistant(_ text: String, sidechain: Bool = false) -> String {
        let side = sidechain ? #""isSidechain":true,"# : ""
        return #"{"type":"assistant",\#(side)"message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func typedUser(_ text: String) -> String {
        #"{"type":"user","promptSource":"typed","message":{"content":"\#(text)"}}"#
    }

    private func toolResultUser() -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"…"}]}}"#
    }

    func testReturnsLatestAssistantTextAfterTypedPrompt() throws {
        try write([
            typedUser("첫 요청"),
            assistant("첫 답변"),
            typedUser("두번째 요청"),
            assistant("진행 중 중간 답변"),
            toolResultUser(),
            assistant("최신 답변\\n둘째 줄은 안 보임"),  // JSON 이스케이프 개행 — 첫 줄만 나와야 한다
        ])
        XCTAssertEqual(
            ClaudeTranscriptTail.latestOutput(transcriptPath: tempFile.path),
            "최신 답변"
        )
    }

    func testNilWhenNewTurnHasNoOutputYet() throws {
        // 새 typed 프롬프트가 마지막 — 직전 턴의 답을 새 작업 출력으로 보이면 안 된다.
        try write([
            assistant("직전 턴의 답"),
            typedUser("방금 낸 새 요청"),
        ])
        XCTAssertNil(ClaudeTranscriptTail.latestOutput(transcriptPath: tempFile.path))
    }

    func testTaskNotificationDoesNotStartANewHumanTurn() throws {
        try write([
            typedUser("요청"),
            assistant("현재 답변"),
            #"{"type":"user","promptSource":"sdk","message":{"content":"<task-notification>완료"}}"#,
        ])
        XCTAssertEqual(
            ClaudeTranscriptTail.latestOutput(transcriptPath: tempFile.path),
            "현재 답변"
        )
    }

    func testSkipsSidechainAndToolOnlyTurns() throws {
        try write([
            typedUser("요청"),
            assistant("본 세션 답변"),
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            assistant("서브에이전트 답", sidechain: true),
        ])
        XCTAssertEqual(
            ClaudeTranscriptTail.latestOutput(transcriptPath: tempFile.path),
            "본 세션 답변"
        )
    }

    func testNilForMissingOrEmptyPath() {
        XCTAssertNil(ClaudeTranscriptTail.latestOutput(transcriptPath: nil))
        XCTAssertNil(ClaudeTranscriptTail.latestOutput(transcriptPath: ""))
        XCTAssertNil(ClaudeTranscriptTail.latestOutput(transcriptPath: "/없는/경로.jsonl"))
    }

    func testRespectsLimit() throws {
        let long = String(repeating: "가", count: 300)
        try write([typedUser("요청"), assistant(long)])
        XCTAssertEqual(
            ClaudeTranscriptTail.latestOutput(transcriptPath: tempFile.path)?.count,
            200
        )
    }
}
