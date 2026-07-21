import Foundation

/// `--scan` 실행 시 GUI 없이 현재 설정 경로로 사용량을 출력한다.
///
/// 설정은 GUI 와 동일하게 UserDefaults("path.<tool>") 를 읽고, 없으면 기본 경로.
enum HeadlessScan {
    static func run() {
        let defaults = UserDefaults.standard
        func path(_ tool: AITool) -> String {
            defaults.string(forKey: "path.\(tool.rawValue)") ?? tool.defaultPath
        }

        var results = UsageScanner.scanAll(
            claude: path(.claudeCode),
            codex: path(.codex),
            openCode: path(.openCode),
            cursor: path(.cursor),
            gemini: path(.gemini),
            qwen: path(.qwen),
            copilot: path(.copilot)
        )

        // --verify-cache: 같은 프로세스에서 한 번 더 스캔해(파일 캐시 워밍 경로)
        // 콜드 스캔과 결과가 완전히 같은지 검증한다.
        if CommandLine.arguments.contains("--verify-cache") {
            let second = UsageScanner.scanAll(
                claude: path(.claudeCode),
                codex: path(.codex),
                openCode: path(.openCode),
                cursor: path(.cursor),
                gemini: path(.gemini),
                qwen: path(.qwen),
                copilot: path(.copilot)
            )
            var allOK = true
            for (a, b) in zip(results, second) {
                let ok = a.usage == b.usage && a.today == b.today && a.daily == b.daily
                    && a.dailyByModel == b.dailyByModel && a.dailyCostByModel == b.dailyCostByModel
                    && a.models == b.models && a.sessionCount == b.sessionCount
                    && a.lastActivity == b.lastActivity && a.costUSD == b.costUSD
                    && a.pathExists == b.pathExists && a.note == b.note
                if !ok { allOK = false }
                print("cache-parity \(a.tool.rawValue): \(ok ? "OK" : "MISMATCH")")
            }
            print(allOK ? "✅ 캐시 패리티: 콜드 == 워밍" : "❌ 캐시 패리티 실패")
        }

        // Cursor 소비 폴백(CSV API) — GUI 스캔과 동일 경로 검증용.
        // providers() 와 같은 이유로 메인 런루프를 펌프하며 완료를 기다린다.
        var cursorDone = false
        Task {
            if let events = await CursorUsageEvents.fetchDaily() {
                CursorUsageEvents.merge(into: &results, result: events)
                print("(Cursor 소비: 대시보드 CSV \(events.events)건 병합)")
            } else {
                print("(Cursor 소비: CSV 폴백 불가 — DB 스캔 값 사용)")
            }
            cursorDone = true
        }
        while !cursorDone {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        for summary in results {
            let u = summary.usage
            print("== \(summary.tool.displayName) ==")
            print("  path      : \(path(summary.tool))")
            print("  TODAY     : \(TokenFormat.grouped(summary.today.total)) (\(TokenFormat.compact(summary.today.total)))")
            print("  total     : \(TokenFormat.grouped(u.total)) (\(TokenFormat.compact(u.total)))")
            print("  input     : \(TokenFormat.grouped(u.input))")
            print("  output    : \(TokenFormat.grouped(u.output))")
            print("  cacheRead : \(TokenFormat.grouped(u.cacheRead))")
            print("  cacheWrite: \(TokenFormat.grouped(u.cacheWrite))")
            print("  reasoning : \(TokenFormat.grouped(u.reasoning))")
            if !summary.models.isEmpty {
                let top = summary.models.sorted { $0.value > $1.value }.prefix(6)
                let parts = top.map { "\($0.key)=\(TokenFormat.compact($0.value))" }
                print("  models    : \(parts.joined(separator: ", "))")
            }
            if summary.costUSD > 0 {
                print("  cost      : $\(String(format: "%.4f", summary.costUSD))")
            }
            print("  sessions  : \(summary.sessionCount)")
            if let last = summary.lastActivity {
                print("  lastActive: \(last)")
            }
            if let note = summary.note {
                print("  note      : \(note)")
            }
        }

        let grandToday = results.reduce(0) { $0 + $1.today.total }
        let grand = results.reduce(0) { $0 + $1.usage.total }
        print("== TODAY TOTAL: \(TokenFormat.grouped(grandToday)) (\(TokenFormat.compact(grandToday))) ==")
        print("== GRAND TOTAL: \(TokenFormat.grouped(grand)) (\(TokenFormat.compact(grand))) ==")
    }

    /// `--providers` — GUI 없이 9개 라이브 프로바이더 쿼터를 감지·조회해 출력(검증용).
    /// 이 기기의 실제 자격증명(파일·keychain·env)을 읽어 세션/주간/크레딧 한도를 찍는다.
    static func providers() {
        // 이 커맨드의 작업은 @MainActor(LiveProvidersManager) 라 메인 스레드가 필요하다.
        // 따라서 메인 스레드를 세마포어로 블로킹하면 안 되고(그러면 MainActor Task 가
        // 영영 못 돎 → 데드락), 완료 플래그가 설 때까지 메인 런루프를 돌린다.
        var finished = false
        Task { @MainActor in
            let mgr = LiveProvidersManager()
            await mgr.detectEnabled()
            let enabled = mgr.enabledIDs.sorted().joined(separator: ", ")
            print("== 감지된 프로바이더 (\(mgr.enabledIDs.count)/\(mgr.orderedRuntimes.count)): \(enabled.isEmpty ? "(없음)" : enabled) ==")
            await mgr.refreshEnabled()
            for rt in mgr.orderedRuntimes where mgr.enabledIDs.contains(rt.provider.id) {
                let p = rt.provider
                print("== \(p.displayName) [\(p.id)] ==")
                guard let snap = mgr.snapshots[p.id] else { print("  (스냅샷 없음)"); continue }
                if let plan = snap.plan, !plan.isEmpty { print("  plan      : \(plan)") }
                if let w = snap.warning { print("  ⚠︎ warning : \(w)") }
                for line in snap.lines { print("  " + describeLine(line)) }
            }
            finished = true
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }

    /// MetricLine 한 줄을 사람이 읽을 문자열로 — 페이스 상태·리셋·만료까지 표현.
    private static func describeLine(_ line: MetricLine) -> String {
        switch line {
        case .progress(let label, let used, let limit, let format, let resetsAt, let periodMs, _):
            var s = "\(label): \(MetricFormat.progressTrailing(used: used, limit: limit, format: format))"
            let state = MeterEngine.state(used: used, limit: limit, format: format,
                                          resetsAt: resetsAt, periodDurationMs: periodMs)
            if let status = state.statusText { s += " [\(status)]" }
            if let trailing = MeterEngine.trailingResetText(used: used, resetsAt: resetsAt,
                                                            periodDurationMs: periodMs) {
                s += " (\(trailing))"
            }
            if let tip = state.tooltip { s += " — \(tip)" }
            return s
        case .values(let label, let values, _, let expiriesAt, _):
            var s = "\(label): \(MetricFormat.values(values))"
            if let soonest = expiriesAt.min(),
               let d = MeterEngine.compactDuration(soonest.timeIntervalSinceNow) {
                s += " (첫 만료까지 \(d))"
            }
            return s
        case .badge(let label, let text, _, _):
            return (label == MetricLine.errorBadgeLabel ? "❌ " : "") + "\(label): \(text)"
        case .text(let label, let value, _, _):
            return "\(label): \(value)"
        }
    }

    /// `--calibrate-test` — 쿼터 %→토큰 캘리브레이터 로직을 합성 시나리오로 검증
    /// (영속화 없음, GUI 상태 무영향).
    static func calibrateTest() {
        var finished = false
        Task { @MainActor in
            let c = QuotaCalibrator(persist: false)
            func check(_ name: String, _ ok: Bool) {
                print("\(ok ? "✅" : "❌") \(name)")
            }

            // ① 첫 기록 = 베이스라인만 (표본 없음)
            c.record(providerID: "claude", label: "Session", usedPercent: 10, cumulativeTokens: 1_000_000)
            check("베이스라인만 (환율 없음)", c.estimate(providerID: "claude", label: "Session", usedPercent: 10) == nil)

            // ② Δ5% / Δ1.2M → 환율 240K tokens/%
            c.record(providerID: "claude", label: "Session", usedPercent: 15, cumulativeTokens: 2_200_000)
            let e1 = c.estimate(providerID: "claude", label: "Session", usedPercent: 25)
            check("환율 240K/% 학습 (25% ≈ 6M 사용)", e1.map { abs($0.usedTokens - 6_000_000) < 1 } ?? false)
            check("남은 75% ≈ 18M", e1.map { abs($0.remainingTokens - 18_000_000) < 1 } ?? false)

            // ③ Δ% < 1 은 베이스라인 유지 (토큰 누적 — 정수 % 플로어 대응)
            c.record(providerID: "claude", label: "Session", usedPercent: 15.4, cumulativeTokens: 2_500_000)
            check("Δ%<1 표본 미채택", c.estimate(providerID: "claude", label: "Session", usedPercent: 25)?.samples == 1)

            // ④ % 하락 = 리셋 → 표본 없이 리베이스, 기존 환율 유지
            c.record(providerID: "claude", label: "Session", usedPercent: 2, cumulativeTokens: 2_600_000)
            check("리셋 후 환율 유지", c.estimate(providerID: "claude", label: "Session", usedPercent: 25)?.samples == 1)

            // ⑤ Δ%>0 인데 Δtokens=0 = 외부 기기 → 표본 버림
            c.record(providerID: "claude", label: "Session", usedPercent: 8, cumulativeTokens: 2_600_000)
            check("외부 기기 표본 버림", c.estimate(providerID: "claude", label: "Session", usedPercent: 25)?.samples == 1)

            // ⑥ 정상 표본 추가 → EWMA 갱신 (240K → 0.7·240K + 0.3·200K = 228K)
            c.record(providerID: "claude", label: "Session", usedPercent: 13, cumulativeTokens: 3_600_000)
            let e2 = c.estimate(providerID: "claude", label: "Session", usedPercent: 10)
            check("EWMA 평활 (1% ≈ 228K)", e2.map { abs($0.usedTokens - 2_280_000) < 1 } ?? false)
            check("표본 수 2", e2?.samples == 2)

            // ⑦ 대상 외 라벨/프로바이더는 무시
            c.record(providerID: "claude", label: "Fable", usedPercent: 50, cumulativeTokens: 9_999_999)
            c.record(providerID: "grok", label: "Session", usedPercent: 50, cumulativeTokens: 9_999_999)
            check("Fable/grok 무시", c.estimate(providerID: "claude", label: "Fable", usedPercent: 50) == nil)

            print(c.estimateText(providerID: "claude", label: "Session", usedPercent: 25) ?? "(추정 없음)")
            finished = true
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// `--agent-store` — GUI 없이 스캔→UsageStore 적재→로드→스냅샷을 검증한다.
    /// `AMON_USAGE_DB` env 로 저장 경로를 오버라이드하면 실 usage.db 를 건드리지 않는다.
    static func agentStore() {
        let defaults = UserDefaults.standard
        func path(_ tool: AITool) -> String {
            defaults.string(forKey: "path.\(tool.rawValue)") ?? tool.defaultPath
        }
        let results = UsageScanner.scanAll(
            claude: path(.claudeCode), codex: path(.codex),
            openCode: path(.openCode), cursor: path(.cursor),
            gemini: path(.gemini), qwen: path(.qwen), copilot: path(.copilot)
        )
        let store = UsageStore()
        store.upsert(summaries: results)

        // 로컬 세션 기록(JSONL 저장소)이 있으면 sessions 테이블에도 미러링.
        let sessions = SessionHistoryStore.load()
        if !sessions.isEmpty { store.upsert(sessions: sessions) }

        print("usage.db: \(store.dbURL.path)")
        print("sessions upserted: \(sessions.count)")
        let loaded = store.load()
        for s in loaded where s.usage.total > 0 || !s.dailyByModel.isEmpty {
            let dailyRows = s.dailyByModel.reduce(0) { $0 + $1.value.count }
            print(
                "  \(s.tool.rawValue): total=\(TokenFormat.compact(s.usage.total)) "
                    + "usage_daily_rows=\(dailyRows) sessions=\(s.sessionCount)"
            )
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("amon-store-snapshot.db")
        if let snap = store.snapshot(to: tmp) {
            let size = (try? Data(contentsOf: snap).count) ?? 0
            let sha = AgentDashboardReporter.sha256(of: snap) ?? "?"
            print("snapshot: \(size) bytes, sha256=\(sha.prefix(12))…")
            try? FileManager.default.removeItem(at: snap)
        } else {
            print("❌ 스냅샷 실패")
        }
    }

    /// `--agent-upload <serverURL> <userKey>` — 스캔→적재→스냅샷→멀티파트 업로드를 검증한다.
    /// 로컬 목 서버로 멀티파트 바디 구성·전송을 실검증할 때 쓴다.
    static func agentUpload() {
        let defaults = UserDefaults.standard
        func path(_ tool: AITool) -> String {
            defaults.string(forKey: "path.\(tool.rawValue)") ?? tool.defaultPath
        }
        var serverURL = defaults.string(forKey: "server.url") ?? ""
        var userKey = defaults.string(forKey: "server.userKey") ?? ""
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--agent-upload") {
            if args.count > i + 1 { serverURL = args[i + 1] }
            if args.count > i + 2 { userKey = args[i + 2] }
        }

        let results = UsageScanner.scanAll(
            claude: path(.claudeCode), codex: path(.codex),
            openCode: path(.openCode), cursor: path(.cursor),
            gemini: path(.gemini), qwen: path(.qwen), copilot: path(.copilot)
        )
        let store = UsageStore()
        store.upsert(summaries: results)
        let sessions = SessionHistoryStore.load()
        if !sessions.isEmpty { store.upsert(sessions: sessions) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("amon-usage-upload-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let snap = store.snapshot(to: tmp) else { print("❌ 스냅샷 실패"); return }
        let sha = AgentDashboardReporter.sha256(of: snap) ?? "?"
        print("→ POST \(AgentDashboardReporter.endpoint(from: serverURL)?.absoluteString ?? "(nil)")")
        print("  snapshot sha256=\(sha.prefix(12))…")

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let bytes = try await AgentDashboardReporter.send(
                    serverURL: serverURL, userKey: userKey, snapshot: snap
                )
                print("✅ 업로드 성공 (서버 저장 \(bytes) bytes)")
            } catch {
                print("❌ 업로드 실패: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
    }

    /// `--check-update <serverURL>` — 최신 버전 확인 결과 출력(검증용).
    /// (nonisolated 함수 안에서 Task 를 만들어 CLI 세마포어와 데드락되지 않게 한다.)
    static func checkUpdate(_ serverURL: String) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            if let info = await Updater.checkLatest(serverURL: serverURL) {
                print(
                    "업데이트 있음: v\(info.version) (현재 \(AppInfo.shortVersion)) "
                        + "sha256=\(info.sha256.prefix(12))… size=\(info.sizeBytes)"
                )
            } else {
                print("업데이트 없음 (현재 \(AppInfo.shortVersion))")
            }
            sem.signal()
        }
        sem.wait()
    }

}
