import Foundation
import XCTest

@testable import AIMonitor

/// Codex 일자 버킷 비례 보정 — Σ(턴 단건)이 최종 누적(권위값)과 어긋나는 rollout
/// (중단/재시도 턴이 누적 카운터에 미반영되는 실측 케이스)에서 Σ(일자) == 세션
/// 누적으로 정합함을 고정한다. windows internal/scan/codex_scale_test.go 와 짝.
final class UsageCodexScaleTests: XCTestCase {
    private var tempDir: URL!
    private let iso = ISO8601DateFormatter()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        UsageScanner.resetScanCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func tokenLine(now: Date, lastIn: Int, cumIn: Int) -> String {
        let ts = iso.string(from: now)
        return #"{"timestamp":"\#(ts)","payload":{"type":"token_count","info":{"#
            + #""total_token_usage":{"input_tokens":\#(cumIn),"cached_input_tokens":0,"#
            + #""output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(cumIn)},"#
            + #""last_token_usage":{"input_tokens":\#(lastIn),"cached_input_tokens":0,"#
            + #""output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(lastIn)}}}}"#
    }

    private func turnContextLine(now: Date, model: String) -> String {
        #"{"timestamp":"\#(iso.string(from: now))","payload":{"type":"turn_context","model":"\#(model)"}}"#
    }

    func testCodexDailyScaledToSessionTotal() throws {
        let now = Date()
        let dir = tempDir.appendingPathComponent("2026/07/07", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // last=100 인 턴 두 개, 최종 누적 150 — Σ턴 200 > 최종 150 (factor 0.75).
        let content = [
            turnContextLine(now: now, model: "gpt-5.5"),
            tokenLine(now: now, lastIn: 100, cumIn: 100),
            tokenLine(now: now, lastIn: 100, cumIn: 150),
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: dir.appendingPathComponent("rollout-scale.jsonl"))

        let summary = UsageScanner.scanCodex(paths: [tempDir.path])
        let day = UsageScanner.dayKey(now)
        XCTAssertEqual(summary.usage.total, 150, "세션 누적은 최종 스냅샷이 권위값")
        XCTAssertEqual(summary.daily[day]?.total, 150, "Σ턴 200 을 0.75 로 스케일")
        XCTAssertEqual(summary.dailyByModel[day]?["gpt-5.5"]?.total, 150)
    }

    func testCodexDailyUnchangedWhenTurnsMatchTotal() throws {
        let now = Date()
        let dir = tempDir.appendingPathComponent("2026/07/07", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content = [
            turnContextLine(now: now, model: "gpt-5.5"),
            tokenLine(now: now, lastIn: 80, cumIn: 80),
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: dir.appendingPathComponent("rollout-exact.jsonl"))

        let summary = UsageScanner.scanCodex(paths: [tempDir.path])
        let day = UsageScanner.dayKey(now)
        XCTAssertEqual(summary.usage.total, 80)
        XCTAssertEqual(summary.daily[day]?.total, 80, "Σ턴 == 최종이면 무보정")
    }
}
