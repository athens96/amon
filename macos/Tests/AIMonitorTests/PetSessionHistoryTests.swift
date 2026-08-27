import XCTest
@testable import AIMonitor

final class PetSessionHistoryTests: XCTestCase {
    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: - Claude

    private func typedUser(_ text: String, ts: String = "2026-08-19T01:00:00Z") -> String {
        #"{"type":"user","promptSource":"typed","timestamp":"\#(ts)","message":{"content":"\#(text)"}}"#
    }

    private func assistant(_ text: String, sidechain: Bool = false) -> String {
        let side = sidechain ? #""isSidechain":true,"# : ""
        return #"{"type":"assistant",\#(side)"message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func testClaudePairsPromptWithLastReplyOfTurn() {
        let turns = PetSessionHistoryLoader.claudeTurns(from: data([
            typedUser("첫 요청"),
            assistant("중간 답"),
            assistant("첫 최종 답"),
            typedUser("둘째 요청"),
            assistant("둘째 답"),
            typedUser("셋째 요청"),  // 아직 응답 없음
        ]))
        XCTAssertEqual(turns.map(\.prompt), ["첫 요청", "둘째 요청", "셋째 요청"])
        XCTAssertEqual(turns.map(\.reply), ["첫 최종 답", "둘째 답", nil])
        XCTAssertNotNil(turns[0].timestamp)
    }

    func testClaudeSkipsSidechainToolResultAndInjected() {
        let turns = PetSessionHistoryLoader.claudeTurns(from: data([
            typedUser("요청"),
            assistant("서브에이전트 답", sidechain: true),
            #"{"type":"user","promptSource":"typed","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user","promptSource":"typed","message":{"content":"<system-reminder>주입"}}"#,
            assistant("본 답"),
        ]))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].reply, "본 답")
    }

    func testClaudeAcceptsSDKPromptSource() {
        // Paseo·cmux 같은 SDK 호스트 세션은 promptSource 가 "sdk" 다(실측).
        let turns = PetSessionHistoryLoader.claudeTurns(from: data([
            #"{"type":"user","promptSource":"sdk","message":{"content":"SDK 요청"}}"#,
            assistant("SDK 답"),
        ]))
        XCTAssertEqual(turns.map(\.prompt), ["SDK 요청"])
        XCTAssertEqual(turns.map(\.reply), ["SDK 답"])
    }

    func testClaudeCapsToMaxTurns() {
        var lines: [String] = []
        for index in 0..<(PetSessionHistoryLoader.maxTurns + 10) {
            lines.append(typedUser("요청 \(index)"))
            lines.append(assistant("답 \(index)"))
        }
        let turns = PetSessionHistoryLoader.claudeTurns(from: data(lines))
        XCTAssertEqual(turns.count, PetSessionHistoryLoader.maxTurns)
        XCTAssertEqual(turns.last?.prompt, "요청 \(PetSessionHistoryLoader.maxTurns + 9)")
    }

    func testClaudeSumsTurnTokensAcrossAssistantCalls() {
        // 텍스트 없는 툴 호출 어시스턴트 라인의 usage 도 턴 토큰에 합산된다.
        let turns = PetSessionHistoryLoader.claudeTurns(from: data([
            typedUser("요청"),
            #"{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":30},"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":140,"output_tokens":50},"content":[{"type":"text","text":"답"}]}}"#,
        ]))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].outputTokens, 80)   // 30 + 50 합산
        XCTAssertEqual(turns[0].inputTokens, 140)   // 마지막 호출의 컨텍스트
        XCTAssertEqual(turns[0].reply, "답")
    }

    // MARK: - Codex

    func testCodexPairsUserAndAgentMessages() {
        let turns = PetSessionHistoryLoader.codexTurns(from: data([
            #"{"type":"event_msg","timestamp":"2026-08-19T02:00:00Z","payload":{"type":"user_message","message":"코덱스 요청"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"코덱스 답"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
        ]))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].prompt, "코덱스 요청")
        XCTAssertEqual(turns[0].reply, "코덱스 답")
    }

    func testCodexTurnTokensAreCumulativeDeltas() {
        func tokenCount(input: Int, cached: Int, output: Int) -> String {
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}}}}"#
        }
        let turns = PetSessionHistoryLoader.codexTurns(from: data([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"첫 턴"}}"#,
            tokenCount(input: 1000, cached: 400, output: 200),  // 누적 input 600 / output 200
            #"{"type":"event_msg","payload":{"type":"user_message","message":"둘째 턴"}}"#,
            tokenCount(input: 1900, cached: 800, output: 350),  // 누적 1100/350 → 델타 500/150
        ]))
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].inputTokens, 600)
        XCTAssertEqual(turns[0].outputTokens, 200)
        XCTAssertEqual(turns[1].inputTokens, 500)
        XCTAssertEqual(turns[1].outputTokens, 150)
    }

    func testCodexFallsBackToResponseItemsWhenNoEventMsg() {
        // 구형 rollout — event_msg 없이 response_item 만 있는 경우.
        let turns = PetSessionHistoryLoader.codexTurns(from: data([
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions 주입"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"구형 요청"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"구형 답"}]}}"#,
        ]))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].prompt, "구형 요청")
        XCTAssertEqual(turns[0].reply, "구형 답")
    }

    func testCodexPrefersEventMsgOverResponseItems() {
        // 신형 rollout 은 둘 다 있을 수 있다 — event_msg 를 쓰면 중복이 안 생긴다.
        let turns = PetSessionHistoryLoader.codexTurns(from: data([
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"중복 요청"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"중복 요청"}}"#,
        ]))
        XCTAssertEqual(turns.count, 1)
    }

    // MARK: - Loader 입구

    func testLoadReturnsEmptyForUnknownProviderOrMissingPath() {
        XCTAssertTrue(PetSessionHistoryLoader.load(provider: "cursor", transcriptPath: "/tmp/x").isEmpty)
        XCTAssertTrue(PetSessionHistoryLoader.load(provider: "claude", transcriptPath: nil).isEmpty)
        XCTAssertTrue(PetSessionHistoryLoader.load(provider: "claude", transcriptPath: "/없는/파일.jsonl").isEmpty)
    }
}

final class PetOverlayHistoryGeometryTests: XCTestCase {
    private let panel = CGSize(width: 500, height: 400)

    func testHistoryControlDoesNotOverlapCarousel() {
        let cardHeight: CGFloat = 200
        let carousel = PetOverlayGeometry.carouselControlFrame(
            in: panel, bubblePlacement: .left, cardHeight: cardHeight
        )
        let history = PetOverlayGeometry.historyControlFrame(
            in: panel, bubblePlacement: .left, cardHeight: cardHeight
        )
        XCTAssertFalse(carousel.intersects(history))
        // 둘 다 말풍선 안에 있어야 한다.
        let bubble = PetOverlayGeometry.bubbleFrame(in: panel, bubblePlacement: .left)
        XCTAssertTrue(bubble.contains(history))
    }

    func testControlsFollowMainCardTopWhenHistoryOpen() {
        // 히스토리로 패널이 커져도(전체 400) 카드(200)는 아래에 남는다 —
        // 버튼 히트존은 카드 상단(minY+200) 기준이어야 한다.
        let cardHeight: CGFloat = 200
        let bubble = PetOverlayGeometry.bubbleFrame(in: panel, bubblePlacement: .left)
        let history = PetOverlayGeometry.historyControlFrame(
            in: panel, bubblePlacement: .left, cardHeight: cardHeight
        )
        XCTAssertEqual(history.maxY, bubble.minY + cardHeight - 40 + 34)
    }

    func testHistoryAreaSitsAboveMainCard() {
        let area = PetOverlayGeometry.historyAreaFrame(
            in: panel, bubblePlacement: .left, historyHeight: 150
        )
        let bubble = PetOverlayGeometry.bubbleFrame(in: panel, bubblePlacement: .left)
        XCTAssertEqual(area.maxY, bubble.maxY)  // 스택은 위쪽에 붙는다
        XCTAssertEqual(area.height, 150)
        XCTAssertTrue(PetOverlayGeometry.historyAreaFrame(
            in: panel, bubblePlacement: .left, historyHeight: 0
        ).isNull)
    }

    func testHistoryHeightUsesSpaceAbovePanelOnly() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 패널 위쪽 공간만 쓴다 — 원점이 안 움직여 펫이 제자리에 있는다.
        XCTAssertEqual(
            PetOverlayGeometry.historyHeight(panelTop: 300, visibleFrame: visible),
            900 - 8 - 300
        )
        // 패널이 화면 위쪽에 붙어 있어 최소 높이가 안 나오면 0 — 열지 않는다.
        XCTAssertEqual(
            PetOverlayGeometry.historyHeight(panelTop: 850, visibleFrame: visible),
            0
        )
    }
}
