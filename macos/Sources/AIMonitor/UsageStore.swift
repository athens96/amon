import CryptoKit
import Foundation
import SQLite3

/// sqlite3_bind_text 용 — 바인딩 후 SQLite 가 문자열을 복사하도록 지시.
private let SQLITE_TRANSIENT_STORE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A-mon 로컬 사용량 저장 계층 (`usage.db`).
///
/// 스캔 결과(도구별 요약)와 종료 세션 기록을 SQLite 에 적재하고, UI 는 여기서 로드해
/// 스캔 전에도 즉시 렌더한다. 에이전트 대시보드 업로드는 이 DB 의 일관 스냅샷을 보낸다.
///
/// 스키마(SPEC §1): meta / usage_daily(date,tool,model) / tool_totals(tool) / sessions(id).
/// 외부 의존성 0 원칙에 따라 시스템 SQLite3 C API 를 직접 쓴다. 모든 공개 메서드는
/// 락으로 직렬화하며, 연산마다 연결을 열고 닫는다(스캔은 직렬이라 경합이 드물다).
/// 락으로 내부 상태를 보호하므로 백그라운드 Task 로 안전하게 넘길 수 있다(@unchecked Sendable).
final class UsageStore: @unchecked Sendable {
    static let shared = UsageStore()

    /// 저장 경로 — 기본 `~/Library/Application Support/A-mon/usage.db`.
    let dbURL: URL
    private let lock = NSLock()

    /// 로컬 타임존 ISO8601(UTC 표기) — meta/last_activity/started_at 저장용.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(dbURL: URL = AmonPaths.usageDB) {
        self.dbURL = dbURL
    }

    // MARK: - 연결 / 스키마

    /// 읽기·쓰기 연결을 열고 스키마를 보장한다. 실패 시 nil.
    private func openRW() -> OpaquePointer? {
        try? FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        exec(db, "PRAGMA journal_mode=WAL;")
        exec(db, "PRAGMA user_version=1;")
        exec(db, Self.schemaSQL)
        return db
    }

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS usage_daily(
      date TEXT NOT NULL, tool TEXT NOT NULL, model TEXT NOT NULL DEFAULT '',
      input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
      cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
      reasoning INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0,
      cost_usd REAL, PRIMARY KEY(date, tool, model));
    CREATE TABLE IF NOT EXISTS tool_totals(
      tool TEXT PRIMARY KEY,
      input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
      cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
      reasoning INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0,
      cost_usd REAL, sessions INTEGER NOT NULL DEFAULT 0,
      last_activity TEXT, models_json TEXT NOT NULL DEFAULT '{}',
      path_exists INTEGER NOT NULL DEFAULT 0, note TEXT);
    CREATE TABLE IF NOT EXISTS sessions(
      id TEXT PRIMARY KEY, tool TEXT NOT NULL, session_id TEXT NOT NULL,
      project TEXT, git_branch TEXT, started_at TEXT, ended_at TEXT,
      input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
      cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
      total INTEGER NOT NULL DEFAULT 0, cost_usd REAL,
      models_json TEXT NOT NULL DEFAULT '[]',
      prompt_count INTEGER NOT NULL DEFAULT 0, first_prompt TEXT,
      agent_count INTEGER NOT NULL DEFAULT 0);
    """

    // MARK: - 스캔 요약 적재

    /// 스캔 요약을 usage_daily/tool_totals/meta 에 반영한다.
    /// usage_daily 는 스캔 창(오늘 포함 30일) 이내 행만 지우고 다시 넣어 과거 이력을 보존한다.
    func upsert(summaries: [ToolUsageSummary],
                machine: String = ProcessInfo.processInfo.hostName,
                appVersion: String = AppInfo.shortVersion,
                deviceID: String = AmonDeviceID.current) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = openRW() else { return }
        defer { sqlite3_close(db) }

        let windowKey = UsageScanner.dayKey(UsageScanner.windowStart())
        exec(db, "BEGIN IMMEDIATE;")

        // meta
        setMeta(db, "schema_version", "1")
        setMeta(db, "generated_at", Self.iso.string(from: Date()))
        setMeta(db, "machine", machine)
        setMeta(db, "app_version", appVersion)
        // 서버 디바이스 분리 키 — 호스트명과 달리 네트워크에 따라 변하지 않는다.
        setMeta(db, "device_id", deviceID)

        for summary in summaries {
            let tool = summary.tool.rawValue

            // usage_daily — 창 이내 행 교체(창 이전은 과거 스캔분 보존).
            if let del = prepare(db, "DELETE FROM usage_daily WHERE tool=? AND date>=?;") {
                bindText(del, 1, tool)
                bindText(del, 2, windowKey)
                sqlite3_step(del)
                sqlite3_finalize(del)
            }
            let insSQL = """
            INSERT OR REPLACE INTO usage_daily
              (date,tool,model,input,output,cache_read,cache_write,reasoning,total,cost_usd)
              VALUES(?,?,?,?,?,?,?,?,?,?);
            """
            if let ins = prepare(db, insSQL) {
                for (date, byModel) in summary.dailyByModel where date >= windowKey {
                    for (model, u) in byModel {
                        sqlite3_reset(ins)
                        sqlite3_clear_bindings(ins)
                        bindText(ins, 1, date)
                        bindText(ins, 2, tool)
                        bindText(ins, 3, model)
                        sqlite3_bind_int64(ins, 4, Int64(u.input))
                        sqlite3_bind_int64(ins, 5, Int64(u.output))
                        sqlite3_bind_int64(ins, 6, Int64(u.cacheRead))
                        sqlite3_bind_int64(ins, 7, Int64(u.cacheWrite))
                        sqlite3_bind_int64(ins, 8, Int64(u.reasoning))
                        sqlite3_bind_int64(ins, 9, Int64(u.total))
                        if let cost = summary.dailyCostByModel[date]?[model] {
                            sqlite3_bind_double(ins, 10, cost)
                        } else {
                            sqlite3_bind_null(ins, 10)
                        }
                        sqlite3_step(ins)
                    }
                }
                sqlite3_finalize(ins)
            }

            // tool_totals — 전체 누적 스냅샷.
            let ttSQL = """
            INSERT OR REPLACE INTO tool_totals
              (tool,input,output,cache_read,cache_write,reasoning,total,cost_usd,
               sessions,last_activity,models_json,path_exists,note)
              VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
            if let tt = prepare(db, ttSQL) {
                let u = summary.usage
                bindText(tt, 1, tool)
                sqlite3_bind_int64(tt, 2, Int64(u.input))
                sqlite3_bind_int64(tt, 3, Int64(u.output))
                sqlite3_bind_int64(tt, 4, Int64(u.cacheRead))
                sqlite3_bind_int64(tt, 5, Int64(u.cacheWrite))
                sqlite3_bind_int64(tt, 6, Int64(u.reasoning))
                sqlite3_bind_int64(tt, 7, Int64(u.total))
                if summary.costUSD != 0 { sqlite3_bind_double(tt, 8, summary.costUSD) }
                else { sqlite3_bind_null(tt, 8) }
                sqlite3_bind_int64(tt, 9, Int64(summary.sessionCount))
                if let last = summary.lastActivity { bindText(tt, 10, Self.iso.string(from: last)) }
                else { sqlite3_bind_null(tt, 10) }
                bindText(tt, 11, jsonObjectString(summary.models))
                sqlite3_bind_int64(tt, 12, summary.pathExists ? 1 : 0)
                if let note = summary.note { bindText(tt, 13, note) }
                else { sqlite3_bind_null(tt, 13) }
                sqlite3_step(tt)
                sqlite3_finalize(tt)
            }
        }

        exec(db, "COMMIT;")
    }

    // MARK: - 세션 기록 미러

    /// 종료 세션 기록을 sessions 테이블에 upsert 하고 최대 2000행으로 캡한다.
    func upsert(sessions records: [SessionRecord]) {
        guard !records.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = openRW() else { return }
        defer { sqlite3_close(db) }

        exec(db, "BEGIN IMMEDIATE;")
        let sql = """
        INSERT OR REPLACE INTO sessions
          (id,tool,session_id,project,git_branch,started_at,ended_at,
           input,output,cache_read,cache_write,total,cost_usd,models_json,
           prompt_count,first_prompt,agent_count)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        if let ins = prepare(db, sql) {
            for r in records {
                sqlite3_reset(ins)
                sqlite3_clear_bindings(ins)
                bindText(ins, 1, r.id)
                bindText(ins, 2, Self.toolKey(forProvider: r.provider))
                bindText(ins, 3, r.sessionId)
                bindTextOrNull(ins, 4, r.projectLabel.isEmpty ? nil : r.projectLabel)
                bindTextOrNull(ins, 5, r.gitBranch)
                bindText(ins, 6, Self.iso.string(from: r.startedAt))
                bindText(ins, 7, Self.iso.string(from: r.endedAt))
                sqlite3_bind_int64(ins, 8, Int64(r.inputTokens))
                sqlite3_bind_int64(ins, 9, Int64(r.outputTokens))
                // SessionRecord 는 캐시를 분해하지 않는다 — 합계를 cache_read 로 둔다.
                sqlite3_bind_int64(ins, 10, Int64(r.cacheTokens))
                sqlite3_bind_int64(ins, 11, 0)
                sqlite3_bind_int64(ins, 12, Int64(r.totalTokens))
                sqlite3_bind_null(ins, 13)  // cost 는 서버가 요율표로 계산
                bindText(ins, 14, jsonArrayString(Array(r.models.keys).sorted()))
                sqlite3_bind_int64(ins, 15, Int64(r.promptCount))
                bindTextOrNull(ins, 16, r.prompts.first)
                sqlite3_bind_int64(ins, 17, Int64(r.agentCount))
                sqlite3_step(ins)
            }
            sqlite3_finalize(ins)
        }
        exec(db, """
        DELETE FROM sessions WHERE id NOT IN
          (SELECT id FROM sessions ORDER BY ended_at DESC LIMIT 2000);
        """)
        exec(db, "COMMIT;")
    }

    // MARK: - 로드 (UI 선렌더)

    /// tool_totals + usage_daily 로 요약을 재구성한다. 모든 도구를 채워 반환하며,
    /// DB 에 없는 도구는 빈 요약이 된다.
    func load() -> [ToolUsageSummary] {
        lock.lock()
        defer { lock.unlock() }
        var summaries = AITool.allCases.map { ToolUsageSummary(tool: $0) }
        var index: [String: Int] = [:]
        for (i, s) in summaries.enumerated() { index[s.tool.rawValue] = i }

        guard let db = openRW() else { return summaries }
        defer { sqlite3_close(db) }

        // tool_totals
        if let stmt = prepare(db, """
        SELECT tool,input,output,cache_read,cache_write,reasoning,total,cost_usd,
               sessions,last_activity,models_json,path_exists,note FROM tool_totals;
        """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let toolC = sqlite3_column_text(stmt, 0),
                      let i = index[String(cString: toolC)] else { continue }
                summaries[i].usage = TokenUsage(
                    input: Int(sqlite3_column_int64(stmt, 1)),
                    output: Int(sqlite3_column_int64(stmt, 2)),
                    cacheRead: Int(sqlite3_column_int64(stmt, 3)),
                    cacheWrite: Int(sqlite3_column_int64(stmt, 4)),
                    reasoning: Int(sqlite3_column_int64(stmt, 5)),
                    total: Int(sqlite3_column_int64(stmt, 6))
                )
                if sqlite3_column_type(stmt, 7) != SQLITE_NULL {
                    summaries[i].costUSD = sqlite3_column_double(stmt, 7)
                }
                summaries[i].sessionCount = Int(sqlite3_column_int64(stmt, 8))
                if let s = sqlite3_column_text(stmt, 9) {
                    summaries[i].lastActivity = Self.iso.date(from: String(cString: s))
                }
                if let s = sqlite3_column_text(stmt, 10) {
                    summaries[i].models = parseJSONObject(String(cString: s))
                }
                summaries[i].pathExists = sqlite3_column_int64(stmt, 11) != 0
                if let s = sqlite3_column_text(stmt, 12) {
                    summaries[i].note = String(cString: s)
                }
            }
            sqlite3_finalize(stmt)
        }

        // usage_daily → daily + dailyByModel
        if let stmt = prepare(db, """
        SELECT date,tool,model,input,output,cache_read,cache_write,reasoning,total,cost_usd
          FROM usage_daily;
        """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let dateC = sqlite3_column_text(stmt, 0),
                      let toolC = sqlite3_column_text(stmt, 1),
                      let i = index[String(cString: toolC)] else { continue }
                let date = String(cString: dateC)
                let model = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let u = TokenUsage(
                    input: Int(sqlite3_column_int64(stmt, 3)),
                    output: Int(sqlite3_column_int64(stmt, 4)),
                    cacheRead: Int(sqlite3_column_int64(stmt, 5)),
                    cacheWrite: Int(sqlite3_column_int64(stmt, 6)),
                    reasoning: Int(sqlite3_column_int64(stmt, 7)),
                    total: Int(sqlite3_column_int64(stmt, 8))
                )
                summaries[i].daily[date, default: TokenUsage()] += u
                summaries[i].dailyByModel[date, default: [:]][model, default: TokenUsage()] += u
                if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                    summaries[i].dailyCostByModel[date, default: [:]][model, default: 0]
                        += sqlite3_column_double(stmt, 9)
                }
            }
            sqlite3_finalize(stmt)
        }

        let todayKey = UsageScanner.dayKey(Date())
        for i in summaries.indices {
            summaries[i].today = summaries[i].daily[todayKey] ?? TokenUsage()
        }
        return summaries
    }

    // MARK: - 논리 콘텐츠 서명 (업로드 변경 감지)

    /// usage_daily/tool_totals/sessions 를 결정적 순서로 직렬화한 SHA-256(hex).
    /// meta(= generated_at 포함)는 제외하므로 매 스캔 generated_at 이 바뀌어도 내용이
    /// 같으면 서명이 같다. 파일 바이트 SHA 는 generated_at 때문에 항상 달라져 쓸 수 없다.
    func contentSignature() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let db = openRW() else { return "" }
        defer { sqlite3_close(db) }

        var hasher = SHA256()
        func feed(_ s: String) { hasher.update(data: Data(s.utf8)) }
        func hashRows(_ tag: String, _ sql: String, _ cols: Int32) {
            feed("|\(tag)|")
            guard let stmt = prepare(db, sql) else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                for c in 0..<cols {
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_NULL: feed("\u{01}")
                    case SQLITE_INTEGER: feed(String(sqlite3_column_int64(stmt, c)))
                    case SQLITE_FLOAT: feed(String(sqlite3_column_double(stmt, c)))
                    default:
                        if let t = sqlite3_column_text(stmt, c) { feed(String(cString: t)) }
                    }
                    feed("\u{02}")
                }
                feed("\n")
            }
        }
        hashRows("usage_daily", """
        SELECT date,tool,model,input,output,cache_read,cache_write,reasoning,total,cost_usd
          FROM usage_daily ORDER BY date,tool,model;
        """, 10)
        hashRows("tool_totals", """
        SELECT tool,input,output,cache_read,cache_write,reasoning,total,cost_usd,sessions,
               last_activity,models_json,path_exists,note FROM tool_totals ORDER BY tool;
        """, 13)
        hashRows("sessions", """
        SELECT id,tool,session_id,project,git_branch,started_at,ended_at,input,output,
               cache_read,cache_write,total,cost_usd,models_json,prompt_count,first_prompt,
               agent_count FROM sessions ORDER BY id;
        """, 17)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 업로드 스냅샷

    /// `VACUUM INTO` 로 일관 스냅샷을 만든다. 성공 시 대상 URL, 실패 시 nil.
    /// 대상 파일이 이미 있으면 지운다(VACUUM INTO 는 기존 파일을 덮어쓰지 못한다).
    func snapshot(to target: URL) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: target)
        guard let db = openRW() else { return nil }
        defer { sqlite3_close(db) }
        // WAL 을 본 파일로 합쳐 스냅샷이 최신 내용을 담게 한다.
        exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
        let escaped = target.path.replacingOccurrences(of: "'", with: "''")
        return exec(db, "VACUUM INTO '\(escaped)';") ? target : nil
    }

    // MARK: - 헬퍼

    private static func toolKey(forProvider provider: String) -> String {
        switch provider {
        case "claude": return AITool.claudeCode.rawValue
        case "codex": return AITool.codex.rawValue
        default: return provider
        }
    }

    @discardableResult
    private func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(stmt, idx, $0, -1, SQLITE_TRANSIENT_STORE) }
    }

    private func bindTextOrNull(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let value { bindText(stmt, idx, value) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func setMeta(_ db: OpaquePointer, _ key: String, _ value: String) {
        guard let stmt = prepare(db, "INSERT OR REPLACE INTO meta(key,value) VALUES(?,?);") else { return }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func jsonObjectString(_ dict: [String: Int]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func jsonArrayString(_ arr: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private func parseJSONObject(_ s: String) -> [String: Int] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: Int] = [:]
        for (k, v) in obj {
            if let n = v as? Int { out[k] = n }
            else if let n = v as? NSNumber { out[k] = n.intValue }
        }
        return out
    }
}
