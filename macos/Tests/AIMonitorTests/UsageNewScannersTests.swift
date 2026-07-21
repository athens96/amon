import Foundation
import XCTest
@testable import AIMonitor

/// 신규 스캐너 3종(Gemini/Qwen/Copilot)과 로컬 SQLite 저장 계층(UsageStore)의
/// SPEC §1·§2 매핑을 고정하는 테스트. 합성 픽스처로 정확한 기대값을 검증한다.
final class UsageNewScannersTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ text: String, to relative: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Gemini

    func testGeminiAppliesCumulativeDeltas() throws {
        // tokens.input/cached 는 세션 누적값 → 메시지 순서대로 델타. output/thoughts 는 그대로.
        // a1(first): Δinput=1000, Δcached=100, output=250, total=1350
        // a2: Δinput=2000-1000=1000, Δcached=0-100<0→raw 0, output=300, total=1300
        _ = try write("""
        {"sessionId":"g1","startTime":"2026-07-10T03:00:00Z","kind":"main"}
        {"id":"u1","type":"user","content":"hi","timestamp":"2026-07-10T03:00:00Z"}
        {"id":"a1","type":"gemini","model":"gemini-2.5-pro","timestamp":"2026-07-10T03:00:01Z","tokens":{"input":1000,"cached":100,"output":200,"thoughts":50}}
        {"id":"a2","type":"gemini","model":"gemini-2.5-pro","timestamp":"2026-07-10T03:00:02Z","tokens":{"input":2000,"cached":0,"output":300,"thoughts":0}}
        """, to: "tmp/hashA/chats/session-a.jsonl")
        // 단일 JSON 오브젝트 세션 — b1(first): Δinput=500, Δcached=50, output=110, total=660.
        _ = try write("""
        {"sessionId":"g2","messages":[
          {"id":"u1","type":"user","content":"q","timestamp":"2026-07-10T03:00:00Z"},
          {"id":"a1","type":"gemini","model":"gemini-1.5-flash","timestamp":"2026-07-10T03:00:03Z","tokens":{"input":500,"cached":50,"output":100,"thoughts":10}}
        ]}
        """, to: "tmp/hashB/chats/session-b.json")

        let s = UsageScanner.scanGemini(
            path: tempDir.appendingPathComponent("tmp").path, windowStart: .distantPast
        )
        XCTAssertEqual(s.sessionCount, 2)
        XCTAssertEqual(s.usage.input, 2500)      // (1000+1000)+500
        XCTAssertEqual(s.usage.output, 660)      // (250+300)+110
        XCTAssertEqual(s.usage.cacheRead, 150)   // (100+0)+50
        XCTAssertEqual(s.usage.cacheWrite, 0)
        XCTAssertEqual(s.usage.reasoning, 60)
        XCTAssertEqual(s.usage.total, 3310)
        XCTAssertEqual(s.models["gemini-2.5-pro"], 2650)   // 1350+1300
        XCTAssertEqual(s.models["gemini-1.5-flash"], 660)
        XCTAssertEqual(s.dailyByModel["2026-07-10"]?["gemini-2.5-pro"]?.total, 2650)
    }

    // MARK: - Qwen

    func testQwenSumsPerLine() throws {
        _ = try write("""
        {"sessionId":"q1","type":"user","cwd":"/x","timestamp":"2026-07-10T03:00:00Z","message":{"role":"user","parts":[{"text":"calc"}]}}
        {"sessionId":"q1","type":"assistant","model":"qwen3-coder","timestamp":"2026-07-10T03:00:01Z","message":{"role":"model","parts":[{"text":"r"}]},"usageMetadata":{"promptTokenCount":1000,"candidatesTokenCount":50,"cachedContentTokenCount":100,"thoughtsTokenCount":20}}
        {"sessionId":"q1","type":"assistant","model":"qwen3-coder","timestamp":"2026-07-10T03:00:02Z","message":{"role":"model","parts":[{"functionCall":{"id":"c1","name":"read"}}]},"usageMetadata":{"promptTokenCount":1200,"candidatesTokenCount":30,"cachedContentTokenCount":200,"thoughtsTokenCount":0}}
        """, to: "projects/proj1/session-q.jsonl")

        let s = UsageScanner.scanQwen(
            path: tempDir.appendingPathComponent("projects").path, windowStart: .distantPast
        )
        XCTAssertEqual(s.sessionCount, 1)
        XCTAssertEqual(s.usage.input, 1900)      // (1000-100)+(1200-200)
        XCTAssertEqual(s.usage.output, 100)      // (50+20)+(30+0)
        XCTAssertEqual(s.usage.cacheRead, 300)
        XCTAssertEqual(s.usage.reasoning, 20)
        XCTAssertEqual(s.usage.total, 2300)
        XCTAssertEqual(s.models["qwen3-coder"], 2300)
    }

    // MARK: - Copilot

    func testCopilotUsesShutdownMetricsAndDedupesLayout() throws {
        _ = try write("""
        {"type":"session.start","timestamp":"2026-07-10T03:00:00Z","data":{"sessionId":"uuidA"}}
        {"type":"session.shutdown","timestamp":"2026-07-10T03:00:05Z","data":{"modelMetrics":{"claude-sonnet-4.6":{"usage":{"inputTokens":1000,"cacheReadTokens":600,"cacheWriteTokens":100,"outputTokens":50,"reasoningTokens":10}}}}}
        """, to: "session-state/uuidA.jsonl")
        _ = try write("""
        {"type":"session.shutdown","timestamp":"2026-07-10T03:00:05Z","data":{"modelMetrics":{"gpt-5.4":{"usage":{"inputTokens":800,"outputTokens":40}}}}}
        """, to: "session-state/uuidB/events.jsonl")
        // 같은 uuid 의 flat 파일은 dir 형(events.jsonl)이 있으면 무시돼야 한다.
        _ = try write("""
        {"type":"session.shutdown","timestamp":"2026-07-10T03:00:05Z","data":{"modelMetrics":{"gpt-5.4":{"usage":{"inputTokens":999999,"outputTokens":999999}}}}}
        """, to: "session-state/uuidB.jsonl")

        let s = UsageScanner.scanCopilot(
            path: tempDir.appendingPathComponent("session-state").path, windowStart: .distantPast
        )
        XCTAssertEqual(s.sessionCount, 2)
        XCTAssertEqual(s.usage.input, 1100)      // max(1000-600-100,0)=300 + 800
        XCTAssertEqual(s.usage.output, 90)
        XCTAssertEqual(s.usage.cacheRead, 600)
        XCTAssertEqual(s.usage.cacheWrite, 100)
        XCTAssertEqual(s.usage.reasoning, 10)
        XCTAssertEqual(s.usage.total, 1890)      // decoy(999999) 무시 확인
        XCTAssertEqual(s.models["claude-sonnet-4-6"], 1050)  // claude-sonnet-4.6 정규화
        XCTAssertEqual(s.models["gpt-5.4"], 840)             // claude 아님 → 그대로
    }

    // MARK: - Codex 크로스-root 하드링크 dedup

    /// rollout 파일명(세션당 전역 유일) 기준으로 하드링크된 세션이 두 root 병합 시
    /// 이중 집계되지 않아야 한다.
    func testCodexCrossRootHardlinkDedup() throws {
        let fm = FileManager.default
        let dirA = tempDir.appendingPathComponent("codexA/sessions/2026/07/10")
        let dirB = tempDir.appendingPathComponent("codexB/sessions/2026/07/10")
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)

        func rollout(total: Int) -> String {
            let tc = #"{"type":"turn_context","payload":{"model":"gpt-5"}}"#
            let tk = "{\"timestamp\":\"2026-07-10T03:00:00Z\",\"type\":\"event_msg\","
                + "\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":"
                + "{\"input_tokens\":\(total),\"cached_input_tokens\":0,\"output_tokens\":0,"
                + "\"reasoning_output_tokens\":0,\"total_tokens\":\(total)}}}}"
            return tc + "\n" + tk + "\n"
        }
        let f1 = dirA.appendingPathComponent("rollout-2026-07-10T03-00-00-uuid1.jsonl")
        let f2 = dirA.appendingPathComponent("rollout-2026-07-10T03-00-01-uuid2.jsonl")
        try Data(rollout(total: 100).utf8).write(to: f1)
        try Data(rollout(total: 200).utf8).write(to: f2)
        // rootB: uuid1 은 하드링크(공유 세션), uuid3 는 rootB 고유.
        try fm.linkItem(
            at: f1, to: dirB.appendingPathComponent("rollout-2026-07-10T03-00-00-uuid1.jsonl")
        )
        try Data(rollout(total: 50).utf8).write(
            to: dirB.appendingPathComponent("rollout-2026-07-10T03-00-02-uuid3.jsonl")
        )

        let rootA = tempDir.appendingPathComponent("codexA/sessions").path
        let rootB = tempDir.appendingPathComponent("codexB/sessions").path
        UsageScanner.resetScanCache()
        let both = UsageScanner.scanCodex(paths: [rootA, rootB], windowStart: .distantPast)
        XCTAssertEqual(both.sessionCount, 3)      // uuid1(1회)·uuid2·uuid3
        XCTAssertEqual(both.usage.total, 350)     // 100+200+50, 하드링크 중복 없음

        UsageScanner.resetScanCache()
        let onlyA = UsageScanner.scanCodex(paths: [rootA], windowStart: .distantPast)
        XCTAssertEqual(onlyA.sessionCount, 2)     // 단일 root 는 dedup 영향 없음
        XCTAssertEqual(onlyA.usage.total, 300)
    }

    /// 실데이터: `~/.codex/sessions`(orca 하드링크 서브셋) + orca 를 병합해도 orca 단독과
    /// 동일해야 한다(이중 집계 없음). 데이터 없으면 스킵.
    func testCodexRealDataTwoRootsEqualOrcaAlone() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codex = home.appendingPathComponent(".codex/sessions").path
        let orca = home.appendingPathComponent(
            "Library/Application Support/orca/codex-runtime-home/home/sessions"
        ).path
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: codex, isDirectory: &isDir), isDir.boolValue,
              fm.fileExists(atPath: orca, isDirectory: &isDir), isDir.boolValue
        else { throw XCTSkip("codex/orca 실데이터 없음") }

        UsageScanner.resetScanCache()
        let both = UsageScanner.scanCodex(paths: [codex, orca], windowStart: .distantPast)
        UsageScanner.resetScanCache()
        let orcaOnly = UsageScanner.scanCodex(paths: [orca], windowStart: .distantPast)
        XCTAssertEqual(both.sessionCount, orcaOnly.sessionCount)
        XCTAssertEqual(both.usage.total, orcaOnly.usage.total)
    }

    // MARK: - UsageStore 라운드트립

    func testUsageStoreRoundTrip() throws {
        let dbURL = tempDir.appendingPathComponent("usage.db")
        let store = UsageStore(dbURL: dbURL)

        var gemini = ToolUsageSummary(tool: .gemini)
        gemini.usage = TokenUsage(input: 3000, output: 550, cacheRead: 100, cacheWrite: 0, reasoning: 50, total: 3650)
        gemini.models = ["gemini-2.5-pro": 3650]
        gemini.sessionCount = 1
        let today = UsageScanner.dayKey(Date())
        gemini.dailyByModel = [today: ["gemini-2.5-pro": gemini.usage]]

        var openCode = ToolUsageSummary(tool: .openCode)
        openCode.usage = TokenUsage(input: 10, output: 20, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 30)
        openCode.costUSD = 0.5
        openCode.dailyByModel = [today: ["claude-x": openCode.usage]]
        openCode.dailyCostByModel = [today: ["claude-x": 0.5]]

        store.upsert(summaries: [gemini, openCode])

        let loaded = store.load()
        let g = loaded.first { $0.tool == .gemini }
        XCTAssertEqual(g?.usage.total, 3650)
        XCTAssertEqual(g?.models["gemini-2.5-pro"], 3650)
        XCTAssertEqual(g?.dailyByModel[today]?["gemini-2.5-pro"]?.total, 3650)
        let o = loaded.first { $0.tool == .openCode }
        XCTAssertEqual(o?.dailyCostByModel[today]?["claude-x"], 0.5)

        // 세션 upsert — provider 는 AITool rawValue 로 매핑된다.
        let rec = SessionRecord(
            provider: "claude", sessionId: "s1", projectLabel: "proj", gitBranch: "main",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            prompts: ["first prompt"], promptCount: 3, currentTask: nil, lastResult: nil,
            inputTokens: 100, outputTokens: 200, cacheTokens: 50, totalTokens: 350,
            models: ["claude-opus-4-8": 350], agentCount: 2, sourcePath: nil
        )
        store.upsert(sessions: [rec])

        // 스냅샷은 유효한 SQLite(매직바이트) 파일이어야 한다.
        let snap = tempDir.appendingPathComponent("snap.db")
        XCTAssertNotNil(store.snapshot(to: snap))
        let head = try Data(contentsOf: snap).prefix(16)
        XCTAssertEqual(head, Data("SQLite format 3\0".utf8))
    }

    func testContentSignatureIgnoresGeneratedAtButTracksContent() throws {
        let store = UsageStore(dbURL: tempDir.appendingPathComponent("usage.db"))
        let today = UsageScanner.dayKey(Date())
        var g = ToolUsageSummary(tool: .gemini)
        g.usage = TokenUsage(input: 10, output: 20, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 30)
        g.dailyByModel = [today: ["m": g.usage]]

        store.upsert(summaries: [g])
        let sig1 = store.contentSignature()
        XCTAssertFalse(sig1.isEmpty)

        // 같은 내용 재적재 — generated_at 만 갱신되지만 논리 서명은 동일해야 한다.
        store.upsert(summaries: [g])
        XCTAssertEqual(store.contentSignature(), sig1)

        // 내용이 바뀌면 서명도 바뀌어야 한다.
        g.usage = TokenUsage(input: 10, output: 999, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 1009)
        g.dailyByModel = [today: ["m": g.usage]]
        store.upsert(summaries: [g])
        XCTAssertNotEqual(store.contentSignature(), sig1)
    }
}
