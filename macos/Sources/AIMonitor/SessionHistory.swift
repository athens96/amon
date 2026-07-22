import Foundation

/// 종료된 세션 1건 — Claude Code(훅) · Codex CLI(로그 스캔) 공용 레코드.
///
/// `currentTask`/`lastResult` 는 각각 마지막 요청·응답의 **첫 줄 요약**이다.
/// 전체 프롬프트/응답 본문은 어디에도 저장하지 않는다 — 세션 상세를 열 때
/// `sourcePath` 의 원본 로그를 그 자리에서 읽는다(`SessionTranscriptLoader`).
struct SessionRecord: Codable, Equatable, Identifiable {
    /// 한 세션에 보관하는 요청 줄 수 상한 — 넘으면 최근 것부터 남긴다.
    static let maxPrompts = 50

    var provider: String  // "claude" | "codex" | "cursor" — ProviderIcons 의 id 와 동일
    var sessionId: String
    var projectLabel: String
    var gitBranch: String?
    var startedAt: Date
    var endedAt: Date
    /// 세션 동안의 사용자 요청 첫 줄 목록(시간순, 최대 `maxPrompts` 개).
    var prompts: [String]
    /// 실제 요청 수 — `prompts` 가 잘렸어도 전체 개수를 알 수 있다.
    var promptCount: Int
    /// 마지막 요청(= `prompts.last`). 라이브 화면과 같은 필드명을 쓴다.
    var currentTask: String?
    var lastResult: String?
    var inputTokens: Int
    var outputTokens: Int
    var cacheTokens: Int
    var totalTokens: Int
    var models: [String: Int]
    var agentCount: Int
    /// 이 세션의 원본 로그 경로(Claude 트랜스크립트 · Codex rollout · Cursor state.vscdb).
    /// **로컬 전용** — 세션 상세를 열 때만 쓴다. 옛 기록엔 없을 수 있어 Optional.
    var sourcePath: String?

    /// 같은 세션이 두 번 적재되지 않도록 하는 키(프로바이더 간 id 충돌 방지).
    var id: String { "\(provider):\(sessionId)" }

    /// 로컬 파일·서버 페이로드 모두 snake_case (백엔드 Pydantic 계약과 1:1).
    enum CodingKeys: String, CodingKey {
        case provider
        case sessionId = "session_id"
        case projectLabel = "project_label"
        case gitBranch = "git_branch"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case prompts
        case promptCount = "prompt_count"
        case currentTask = "current_task"
        case lastResult = "last_result"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheTokens = "cache_tokens"
        case totalTokens = "total_tokens"
        case models
        case agentCount = "agent_count"
        case sourcePath = "source_path"
    }
}

/// A-mon 지원 디렉토리 경로 모음 — 훅 스크립트가 쓰는 경로와 반드시 일치해야 한다.
enum AmonPaths {
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/A-mon", isDirectory: true)
    }
    static var live: URL { support.appendingPathComponent("live", isDirectory: true) }
    static var history: URL { support.appendingPathComponent("history", isDirectory: true) }
    /// 훅이 SessionEnd 때 세션 상태를 떨궈 두는 곳 — 앱이 토큰을 붙여 적재하고 지운다.
    static var pending: URL { history.appendingPathComponent("pending", isDirectory: true) }
    static var cache: URL { support.appendingPathComponent("cache", isDirectory: true) }
    static var sessionScanCache: URL { cache.appendingPathComponent("session-scan.json") }
    static var sessionFileCache: URL { cache.appendingPathComponent("session-files.json") }
    /// 적재 완료된 세션 기록(JSONL, 한 줄 = 한 세션).
    static var store: URL { history.appendingPathComponent("sessions.jsonl", isDirectory: false) }
    /// 로컬 사용량 SQLite(에이전트 대시보드 저장 계층). `AMON_USAGE_DB` env 로 오버라이드.
    static var usageDB: URL {
        if let override = ProcessInfo.processInfo.environment["AMON_USAGE_DB"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return support.appendingPathComponent("usage.db", isDirectory: false)
    }
    /// 설치 단위 디바이스 ID 파일 — `AmonDeviceID` 가 읽고 쓴다.
    static var deviceID: URL { support.appendingPathComponent("device-id", isDirectory: false) }
}

/// 설치 단위 안정 디바이스 ID — 서버가 한 유저의 여러 기기를 구분하는 키.
///
/// 호스트명은 접속 네트워크에 따라 바뀔 수 있어 쓰지 않는다(같은 기기가 여러
/// 디바이스로 갈라져 이중 집계됨). 첫 사용 시 UUID 를 만들어 지원 디렉토리
/// 파일로 영속하며, UserDefaults 초기화에도 살아남는다.
enum AmonDeviceID {
    static let current: String = {
        if let saved = try? String(contentsOf: AmonPaths.deviceID, encoding: .utf8) {
            let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(
            at: AmonPaths.support, withIntermediateDirectories: true
        )
        try? fresh.write(to: AmonPaths.deviceID, atomically: true, encoding: .utf8)
        return fresh
    }()
}

/// 파일 단위 세션 파싱 캐시. 한 프로바이더의 활성 로그가 바뀌어도 다른 프로바이더와
/// 과거 세션 파일은 다시 읽지 않는다.
struct SessionFileCacheFile: Codable {
    let version: Int
    var entries: [String: SessionFileCacheEntry]
}

struct SessionFileCacheEntry: Codable {
    let signature: String
    var record: SessionRecord?
    var codexState: CodexRolloutState?
}

struct CodexRolloutState: Codable {
    var offset: UInt64 = 0
    var sessionID: String?
    var cwd: String?
    var model: String?
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var lastUsage: TokenUsage?
    var prompts: [String] = []
    var promptCount = 0
    var seenPrompts: Set<String> = []
    var lastResult: String?
}

enum SessionFileCache {
    /// v2 — 레코드에 `sourcePath` 가 생겨 기존 캐시는 한 번 다시 파싱해야 한다.
    private static let version = 2
    private static let lock = NSLock()
    static var fileURL = AmonPaths.sessionFileCache

    static func load() -> SessionFileCacheFile {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let cache = try? AmonJSON.decoder().decode(SessionFileCacheFile.self, from: data),
              cache.version == version
        else { return SessionFileCacheFile(version: version, entries: [:]) }
        return cache
    }

    static func save(_ cache: SessionFileCacheFile) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? AmonJSON.encoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 종료 세션 원본 로그의 fingerprint와 파싱 결과를 함께 보관한다.
/// 원본 로그가 바뀌지 않은 앱 재실행에서는 JSONL 본문을 다시 읽지 않는다.
struct SessionScanCacheFile: Codable {
    let version: Int
    let generatedAt: Date
    let claudeSignature: String
    let codexSignature: String
    let cursorSignature: String
    let records: [SessionRecord]
}

enum SessionHistoryCache {
    /// v3 — Cursor 세션 스캔이 생겨 cursorSignature 가 추가됐다(구 캐시는 1회 재스캔).
    private static let version = 3

    static func load() -> SessionScanCacheFile? {
        guard let data = try? Data(contentsOf: AmonPaths.sessionScanCache) else { return nil }
        return try? AmonJSON.decoder().decode(SessionScanCacheFile.self, from: data)
    }

    static func save(
        records: [SessionRecord], claudePath: String, codexPath: String, cursorPath: String
    ) {
        let entry = SessionScanCacheFile(
            version: version,
            generatedAt: Date(),
            claudeSignature: sourceSignature(path: claudePath),
            codexSignature: sourceSignature(path: codexPath),
            cursorSignature: cursorSourceSignature(path: cursorPath),
            records: records
        )
        guard let data = try? AmonJSON.encoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: AmonPaths.cache, withIntermediateDirectories: true)
        try? data.write(to: AmonPaths.sessionScanCache, options: .atomic)
    }

    static func matches(
        _ cache: SessionScanCacheFile, claudePath: String, codexPath: String, cursorPath: String
    ) -> Bool {
        cache.version == version
            && cache.claudeSignature == sourceSignature(path: claudePath)
            && cache.codexSignature == sourceSignature(path: codexPath)
            && cache.cursorSignature == cursorSourceSignature(path: cursorPath)
    }

    /// Cursor 전역 DB fingerprint — 본 파일 + `-wal` 의 (size, mtime).
    /// `sourceSignature` 는 jsonl 디렉토리용이라 .vscdb 를 못 봐서 따로 둔다.
    static func cursorSourceSignature(path: String) -> String {
        guard let db = CursorStateDB.resolveGlobalDB(from: path) else { return "empty" }
        return CursorStateDB.signature(db)
    }

    /// 메타데이터만 읽어 fingerprint를 만든다. 파일 본문은 읽지 않는다.
    static func sourceSignature(path: String) -> String {
        guard !path.isEmpty else { return "empty" }
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var parts: [String] = []
        if let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in en where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = values?.fileSize ?? -1
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                parts.append("\(file.path)|\(size)|\(mtime)")
            }
        } else if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            parts.append("\(path)|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.sorted().joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// 훅이 쓰는 ISO8601(마이크로초 없음)과 소수초 있는 형태를 모두 견디는 코더.
enum AmonJSON {
    static func decoder() -> JSONDecoder {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = fractional.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "잘못된 ISO8601: \(s)")
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// 세션 기록 로컬 저장소 — `history/sessions.jsonl` 한 줄에 한 세션.
///
/// 추가 전용(append-only)이고, 읽을 때 `id` 기준으로 최신 것만 남긴다.
/// `maxRecords` 를 넘으면 오래된 순으로 잘라 파일을 다시 쓴다.
enum SessionHistoryStore {
    /// 로컬에 남기는 최대 세션 수 — 넘으면 종료 시각이 오래된 것부터 버린다.
    static let maxRecords = 500

    private static let lock = NSLock()

    /// 저장된 기록을 종료 시각 내림차순으로 읽는다. 파일이 없으면 빈 배열.
    static func load() -> [SessionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private static func loadUnlocked() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: AmonPaths.store), !data.isEmpty else { return [] }
        let decoder = AmonJSON.decoder()
        var byID: [String: SessionRecord] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let record = try? decoder.decode(SessionRecord.self, from: Data(line)) else { continue }
            byID[record.id] = record  // 같은 세션이 다시 적재되면 마지막 것이 이긴다
        }
        return byID.values.sorted { $0.endedAt > $1.endedAt }
    }

    /// 새 기록들을 적재한다(이미 있는 id 는 갱신). 상한을 넘으면 잘라 다시 쓴다.
    /// 실제로 바뀐 게 없으면 파일을 건드리지 않는다.
    @discardableResult
    static func upsert(_ records: [SessionRecord]) -> [SessionRecord] {
        lock.lock()
        defer { lock.unlock() }

        var byID: [String: SessionRecord] = [:]
        for record in loadUnlocked() { byID[record.id] = record }
        var changed = false
        for record in records where byID[record.id] != record {
            byID[record.id] = record
            changed = true
        }
        let merged = byID.values.sorted { $0.endedAt > $1.endedAt }
        let capped = Array(merged.prefix(maxRecords))
        guard changed || capped.count != merged.count else { return merged }

        write(capped)
        return capped
    }

    private static func write(_ records: [SessionRecord]) {
        let encoder = AmonJSON.encoder()
        var blob = Data()
        // 파일은 오래된 것부터(append 로그처럼) 두어 사람이 읽기 쉽게 한다.
        for record in records.reversed() {
            guard let line = try? encoder.encode(record) else { continue }
            blob.append(line)
            blob.append(UInt8(ascii: "\n"))
        }
        try? FileManager.default.createDirectory(
            at: AmonPaths.history, withIntermediateDirectories: true
        )
        try? blob.write(to: AmonPaths.store, options: .atomic)
    }
}
