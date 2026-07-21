import Foundation
import SQLite3

/// sqlite3_bind_text 용 — 바인딩 후 SQLite 가 문자열을 복사하도록 지시.
private let SQLITE_TRANSIENT_CURSOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Cursor 전역 `state.vscdb` 의 `cursorDiskKV` 테이블 리더 — 라이브 파서
/// (`CursorLiveParser`)·세션 기록 스캐너(`SessionHistoryScanner.cursorSessions`)·
/// 상세 대화 로더(`SessionTranscriptLoader`)가 같은 구현을 공유한다.
///
/// 최신 Cursor 는 대화(composer) 데이터를 workspace `ItemTable` 이 아니라 **전역**
/// `cursorDiskKV` 에 저장한다 — `composerData:<composerId>` 한 건 + 메시지별
/// `bubbleId:<composerId>:<bubbleId>` (type 1=user, 2=assistant). workspace DB 에는
/// `hasMigratedComposerData` 플래그와 composer ID 목록만 남는다(실측).
///
/// 실측으로 확인한 함정 두 가지:
/// - DB 가 WAL 저널이라 `immutable=1` 로 열면 체크포인트 전의 최근 대화가 안 보인다.
///   `mode=ro` 를 먼저 시도하고, 그마저 못 읽을 때만 immutable 로 폴백한다.
/// - 신선도 판정도 본 파일 mtime 만 보면 안 된다(체크포인트 전까지 며칠씩 멈춰 있다).
///   `-wal` mtime 까지 함께 본다.
///
/// 목록 조회는 반드시 `key` 레인지(`> 'composerData:' AND < 'composerData;'`)로 —
/// `LIKE` 는 유니크 인덱스를 못 타 2GB DB 풀스캔(~2.3초)이 되지만 레인지는 ~10ms 다.
enum CursorStateDB {

    // MARK: - 경로 / 신선도 / 열기

    static func defaultGlobalDB() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
    }

    /// 설정 경로 → 전역 DB 파일. 설정이 존재하는 .vscdb 파일이면 그대로 쓰고,
    /// 그 외(빈 값·디렉토리·없는 파일)는 기본 전역 경로로 폴백한다 — 설정 기본값
    /// 자체가 전역 DB 파일 경로다(`AITool.cursor.defaultPath`).
    static func resolveGlobalDB(from path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if !trimmed.isEmpty {
            let explicit = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
            if explicit.pathExtension == "vscdb", fm.fileExists(atPath: explicit.path) {
                return explicit
            }
        }
        let fallback = defaultGlobalDB()
        return fm.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// 본 파일과 `-wal` 중 더 최근 mtime — WAL 에만 쌓인 변경도 신선한 것으로 본다.
    static func lastModified(_ db: URL) -> Date? {
        let candidates = [mtime(db), mtime(URL(fileURLWithPath: db.path + "-wal"))]
            .compactMap { $0 }
        return candidates.max()
    }

    /// 캐시 무효화용 fingerprint — 본 파일 + `-wal` 의 (size, mtime).
    static func signature(_ db: URL) -> String {
        [db, URL(fileURLWithPath: db.path + "-wal")]
            .map { url -> String in
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                let size = values?.fileSize ?? -1
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                return "\(size)|\(modified)"
            }
            .joined(separator: "|")
    }

    /// `mode=ro`(WAL 반영) 우선, 읽기 프로브까지 실패하면 `immutable=1` 폴백.
    /// 성공 시 호출자가 닫아야 한다 — 가급적 `withDB` 를 쓸 것.
    static func open(_ db: URL) -> OpaquePointer? {
        guard let encoded = db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        for query in ["mode=ro", "immutable=1"] {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(
                "file:\(encoded)?\(query)", &handle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
            ) == SQLITE_OK, let opened = handle else {
                if let handle { sqlite3_close(handle) }
                continue
            }
            sqlite3_busy_timeout(opened, 500)
            // open 은 lazy 라 여기서 한 번 읽어 봐야 실패가 드러난다
            // (예: -shm 없는 WAL DB 의 read-only 열기).
            if probe(opened) { return opened }
            sqlite3_close(opened)
        }
        return nil
    }

    /// 열고-작업하고-닫기 헬퍼 — 호출자가 SQLite3 를 import 하지 않아도 된다.
    static func withDB<T>(_ url: URL, _ body: (OpaquePointer) -> T) -> T? {
        guard let db = open(url) else { return nil }
        defer { sqlite3_close(db) }
        return body(db)
    }

    private static func probe(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_ROW || rc == SQLITE_DONE
    }

    // MARK: - composer 목록 / 본문

    struct ComposerMeta {
        let id: String
        let createdAt: Date?
        let updatedAt: Date?
    }

    /// 모든 composer 의 (id, createdAt, lastUpdatedAt). JSON 파싱은 SQLite(C) 쪽에서
    /// 하고 값 본문은 Swift 로 가져오지 않는다 — 675개 기준 ~50ms(실측).
    static func composerMetas(_ db: OpaquePointer) -> [ComposerMeta] {
        let sql = """
        SELECT substr(key, 14),
               CAST(json_extract(value, '$.createdAt') AS INTEGER),
               CAST(json_extract(value, '$.lastUpdatedAt') AS INTEGER)
          FROM cursorDiskKV
         WHERE key > 'composerData:' AND key < 'composerData;'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [ComposerMeta] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            out.append(
                ComposerMeta(
                    id: String(cString: idC),
                    createdAt: dateFromMillis(Double(sqlite3_column_int64(stmt, 1))),
                    updatedAt: dateFromMillis(Double(sqlite3_column_int64(stmt, 2)))
                )
            )
        }
        return out
    }

    struct BubbleHeader {
        let bubbleId: String
        /// 1=user, 2=assistant.
        let type: Int
        let createdAt: Date?
    }

    struct Composer {
        let id: String
        /// Cursor 가 붙인 자동 제목("Greeting conversation" 류). 없으면 nil.
        let name: String?
        let createdAt: Date?
        let updatedAt: Date?
        /// `modelConfig.modelName`. 자리채움 값 "default" 는 nil 로 정규화한다.
        let modelName: String?
        let subagentCount: Int
        /// `fullConversationHeadersOnly` — 버블의 시간순 목록(본문은 별도 행).
        let headers: [BubbleHeader]
    }

    static func composer(_ db: OpaquePointer, id: String) -> Composer? {
        guard let raw = value(db, key: "composerData:\(id)"),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        let headers = (obj["fullConversationHeadersOnly"] as? [[String: Any]] ?? [])
            .compactMap { header -> BubbleHeader? in
                guard let bubbleId = header["bubbleId"] as? String else { return nil }
                return BubbleHeader(
                    bubbleId: bubbleId,
                    type: (header["type"] as? NSNumber)?.intValue ?? 0,
                    createdAt: date(header["createdAt"])
                )
            }

        var model = ((obj["modelConfig"] as? [String: Any])?["modelName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if model?.isEmpty != false || model == "default" { model = nil }

        let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Composer(
            id: (obj["composerId"] as? String) ?? id,
            name: (name?.isEmpty == false) ? name : nil,
            createdAt: date(obj["createdAt"]),
            updatedAt: date(obj["lastUpdatedAt"]),
            modelName: model,
            subagentCount: (obj["subagentComposerIds"] as? [Any])?.count ?? 0,
            headers: headers
        )
    }

    /// 버블 하나의 (본문, 시각). 행이 없으면 nil — 본문 없는 버블(툴 스텝 등)은
    /// 빈 문자열로 온다.
    static func bubble(
        _ db: OpaquePointer, composerId: String, bubbleId: String
    ) -> (text: String, createdAt: Date?)? {
        guard let raw = value(db, key: "bubbleId:\(composerId):\(bubbleId)"),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }
        let text = (obj["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (text, date(obj["createdAt"]))
    }

    /// 해당 role 의 가장 최근 본문 첫 줄. 빈 버블(툴 스텝)이 흔해서 뒤에서부터
    /// 훑되 point-lookup 횟수에 상한을 둔다.
    static func latestText(
        _ db: OpaquePointer, composer: Composer, type: Int, limit: Int, fetchCap: Int = 12
    ) -> String? {
        var fetched = 0
        for header in composer.headers.reversed() where header.type == type {
            guard fetched < fetchCap else { break }
            fetched += 1
            guard let bubble = bubble(db, composerId: composer.id, bubbleId: header.bubbleId),
                  !bubble.text.isEmpty
            else { continue }
            return firstLine(bubble.text, limit)
        }
        return nil
    }

    private static func value(_ db: OpaquePointer, key: String) -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM cursorDiskKV WHERE key = ?", -1, &stmt, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT_CURSOR) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(stmt, 0)
        else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    // MARK: - workspace 라벨

    /// composerId → workspace 폴더명. 전역 DB 엔 프로젝트 정보가 없어서 각 workspace
    /// `state.vscdb` 의 `composer.composerData`(마이그레이션 후에도 ID 목록은 남는다)로
    /// 소속을 찾는다. 최근 수정된 workspace 부터 확인하고, 못 찾으면 라벨 없이 둔다.
    static func workspaceLabels(near globalDB: URL, for ids: Set<String>) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        // .../User/globalStorage/state.vscdb → .../User/workspaceStorage
        let root = globalDB
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("workspaceStorage", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [:] }

        let candidates = entries
            .map { $0.appendingPathComponent("state.vscdb") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { (mtime($0) ?? .distantPast) > (mtime($1) ?? .distantPast) }
            .prefix(30)

        var out: [String: String] = [:]
        var remaining = ids
        for dbURL in candidates where !remaining.isEmpty {
            guard let members = workspaceComposerIDs(dbURL) else { continue }
            let hits = remaining.intersection(members)
            guard !hits.isEmpty else { continue }
            remaining.subtract(hits)
            guard let label = workspaceLabel(for: dbURL) else { continue }
            for id in hits { out[id] = label }
        }
        return out
    }

    private static func workspaceComposerIDs(_ dbURL: URL) -> Set<String>? {
        withDB(dbURL) { db -> Set<String> in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT value FROM ItemTable WHERE key = 'composer.composerData'",
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(stmt, 0)
            else { return [] }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            var members: [String] = []
            for key in ["selectedComposerIds", "lastFocusedComposerIds"] {
                members.append(contentsOf: obj[key] as? [String] ?? [])
            }
            if let all = obj["allComposers"] as? [[String: Any]] {
                members.append(contentsOf: all.compactMap { $0["composerId"] as? String })
            }
            return Set(members)
        }
    }

    private static func workspaceLabel(for db: URL) -> String? {
        let workspace = db.deletingLastPathComponent().appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: workspace),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = (obj["folder"] as? String) ?? (obj["workspace"] as? String)
        else { return nil }
        let path = folder.replacingOccurrences(of: "file://", with: "")
        let label = URL(fileURLWithPath: path).lastPathComponent
            .removingPercentEncoding ?? URL(fileURLWithPath: path).lastPathComponent
        return label.isEmpty ? nil : label
    }

    // MARK: - 공용 헬퍼

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// composerData 는 epoch ms 정수, 버블 createdAt 은 ISO 문자열 — 둘 다 받는다.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return dateFromMillis(number.doubleValue) }
        if let s = value as? String {
            if let raw = Double(s) { return dateFromMillis(raw) }
            return fractionalISO.date(from: s) ?? plainISO.date(from: s)
        }
        return nil
    }

    private static func dateFromMillis(_ raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }

    static func firstLine(_ text: String, _ limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first,
              !line.isEmpty
        else { return nil }
        return String(line.prefix(limit))
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
