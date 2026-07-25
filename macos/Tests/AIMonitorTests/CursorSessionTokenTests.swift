import XCTest

@testable import AIMonitor

/// Cursor 세션 토큰 추정 — CSV 이벤트를 최근접 버블 세션에 귀속하는 순수 로직 검증.
final class CursorSessionTokenTests: XCTestCase {

    private func event(
        at t: TimeInterval, model: String = "grok", input: Int = 0, output: Int = 0,
        cacheRead: Int = 0, cacheWrite: Int = 0
    ) -> CursorUsageEvents.RawEvent {
        var usage = TokenUsage()
        usage.input = input
        usage.output = output
        usage.cacheRead = cacheRead
        usage.cacheWrite = cacheWrite
        usage.total = input + output + cacheRead + cacheWrite
        return CursorUsageEvents.RawEvent(
            date: Date(timeIntervalSince1970: t), model: model, usage: usage
        )
    }

    private func bubbles(_ times: [TimeInterval]) -> [Date] {
        times.map { Date(timeIntervalSince1970: $0) }
    }

    func testEventsGoToNearestBubbleSession() {
        let estimates = CursorSessionTokens.attribute(
            events: [
                event(at: 1_010, input: 100, output: 10),
                event(at: 5_020, input: 200, output: 20),
            ],
            sessions: [
                ("a", bubbles([1_000, 1_100])),
                ("b", bubbles([5_000, 5_100])),
            ]
        )
        XCTAssertEqual(estimates["a"]?.usage.total, 110)
        XCTAssertEqual(estimates["b"]?.usage.total, 220)
    }

    func testEventBeyondMaxGapIsDropped() {
        let estimates = CursorSessionTokens.attribute(
            events: [event(at: 1_000 + CursorSessionTokens.maxGap + 1, input: 100)],
            sessions: [("a", bubbles([1_000]))]
        )
        XCTAssertTrue(estimates.isEmpty)
    }

    /// composer 창([created, lastUpdated])이 겹쳐도 버블 거리가 가까운 쪽이 임자다 —
    /// 며칠짜리 창을 가진 유휴 composer 가 남의 이벤트를 흡수하면 안 된다.
    func testOverlappingWindowsResolvedByBubbleDistance() {
        let estimates = CursorSessionTokens.attribute(
            events: [event(at: 5_030, input: 100)],
            sessions: [
                ("wide", bubbles([0, 100_000])),  // 넓은 창, 이벤트 근처엔 버블 없음
                ("near", bubbles([5_000])),
            ]
        )
        XCTAssertNil(estimates["wide"])
        XCTAssertEqual(estimates["near"]?.usage.input, 100)
    }

    func testModelsAndUsageAccumulate() {
        let estimates = CursorSessionTokens.attribute(
            events: [
                event(at: 1_000, model: "grok", input: 10, cacheRead: 5),
                event(at: 1_050, model: "sonnet", output: 7, cacheWrite: 3),
                event(at: 1_090, model: "grok", input: 20),
            ],
            sessions: [("a", bubbles([1_000, 1_100]))]
        )
        let estimate = try! XCTUnwrap(estimates["a"])
        XCTAssertEqual(estimate.usage.input, 30)
        XCTAssertEqual(estimate.usage.output, 7)
        XCTAssertEqual(estimate.usage.cacheRead, 5)
        XCTAssertEqual(estimate.usage.cacheWrite, 3)
        XCTAssertEqual(estimate.usage.total, 45)
        XCTAssertEqual(estimate.models, ["grok": 35, "sonnet": 10])
    }

    func testEmptyBubblesOrEventsYieldNothing() {
        XCTAssertTrue(
            CursorSessionTokens.attribute(events: [event(at: 1)], sessions: [("a", [])]).isEmpty
        )
        XCTAssertTrue(
            CursorSessionTokens.attribute(events: [], sessions: [("a", bubbles([1]))]).isEmpty
        )
    }
}
