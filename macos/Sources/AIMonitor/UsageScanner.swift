import Foundation
import SQLite3

/// sqlite3_bind_text 용 — 바인딩 후 SQLite 가 문자열을 복사하도록 지시.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 로컬 AI 도구 로그를 읽어 토큰 사용량을 집계한다.
///
/// 모든 메서드는 순수 함수(파일 I/O만 수행)이며 백그라운드 스레드에서 호출한다.
/// 파싱은 관용적으로: 알 수 없는 필드는 무시하고, 깨진 라인은 건너뛰며,
/// 경로가 없으면 크래시 대신 `note` 로 사유를 남긴다.
enum UsageScanner {

    // MARK: - 공통 헬퍼

    /// ISO8601 타임스탬프 파서 (소수점 초 포함/미포함 모두 대응).
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// 대시보드 '최근 N일' 표시·미사용 계정 판정에 쓰는 최근 일수 (오늘 포함).
    static let reportWindowDays = 7
    /// 일자별 버킷(daily/dailyByModel) 을 채우는 스캔 창 — 오늘 포함 최근 30일.
    /// SQLite `usage_daily` 저장에 쓰이며, 대시보드는 이 중 최근 7일만 슬라이스해 보여준다.
    static let scanWindowDays = 30

    /// 로컬 "yyyy-MM-dd" 포맷터 — 일자별 버킷 키.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Date → 로컬 "yyyy-MM-dd".
    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Any(주로 NSNumber) → Int 안전 변환.
    private static func int(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? Double { return Int(n) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func bumpLatest(_ current: inout Date?, _ candidate: Date?) {
        guard let candidate else { return }
        if current == nil || candidate > current! { current = candidate }
    }

    /// 확장자로 필터링하며 하위 디렉토리를 모두 순회한다.
    private static func enumerateFiles(root: URL, ext: String, _ body: (URL) -> Void) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in en where url.pathExtension == ext {
            body(url)
        }
    }

    // MARK: - 스캔 간 파일 캐시

    // amon 은 10분마다 로그 트리 전체를 다시 읽는데, 세션 로그는 한 번 닫히면
    // 불변이다. 파일 지문(mtime+size)이 직전 스캔과 같으면 열지도 파싱하지도
    // 않고 캐시된 기여분을 그대로 합산한다 — 정상 사이클의 I/O 가 "트리 전체"
    // 에서 "활성 파일 몇 개"로 줄어든다. 윈도우 앱(internal/scan/cache.go)과
    // 동일 구조.

    /// 파일 변경 감지 지문 — mtime+size 가 같으면 내용이 같다고 본다.
    private struct FileFP: Equatable {
        var mtime: Date?
        var size: Int
    }

    /// 한 파일이 요약에 더하는 값(파일 내 dedup 적용 후). daily 는 절대 날짜
    /// 키로 저장하고, 합산 시점의 창 시작(windowKey)으로 걸러 쓴다 — 창이
    /// 앞으로 굴러도 캐시를 무효화할 필요가 없다.
    private struct Contribution {
        var usage = TokenUsage()
        var models: [String: Int] = [:]
        var daily: [String: TokenUsage] = [:]
        /// 일자→모델→사용량 (usage_daily 저장용). daily 의 모델 분해판.
        var dailyByModel: [String: [String: TokenUsage]] = [:]
    }

    /// Claude 세션 파일 하나의 캐시.
    private final class ClaudeFileEntry {
        var fp = FileFP(mtime: nil, size: -1)
        var keys: [UInt64] = []   // 파일 내 dedup 후 non-anon 키 해시 (등장 순)
        var full = Contribution() // 모든 키를 이 파일이 가진다고 볼 때의 기여분
        /// 파일 간 dedup(--resume 복사)으로 일부 키를 앞 파일에 빼앗겼을 때의
        /// 기여분. 키는 잃은 키 목록의 다이제스트 — 겹침은 안정적이라 보통 0~1개.
        var variants: [UInt64: Contribution] = [:]
    }

    /// Codex rollout 파일 하나의 캐시 — 파일 간 dedup 이 없어 자기완결적이다.
    private final class CodexFileEntry {
        var fp = FileFP(mtime: nil, size: -1)
        var hasData = false // token_count 없는 파일도 기억해 재읽기 방지
        var session = TokenUsage()
        var model = "unknown"
        var daily: [String: TokenUsage] = [:]
        /// 일자→모델→사용량. Codex 는 세션당 단일 모델이라 각 날짜 버킷을 이 모델에 귀속.
        var dailyByModel: [String: [String: TokenUsage]] = [:]
    }

    /// 프로세스 수명 동안 유지되는 파일별 캐시. 스캔은 직렬이지만 안전하게 잠근다.
    private static var claudeCache: [String: ClaudeFileEntry] = [:]
    private static var codexCache: [String: CodexFileEntry] = [:]
    private static let cacheLock = NSLock()

    /// 테스트/검증용: 캐시를 비워 콜드 스캔 상태로 되돌린다.
    static func resetScanCache() {
        cacheLock.lock()
        claudeCache = [:]
        codexCache = [:]
        cacheLock.unlock()
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
    }

    /// 64-bit FNV-1a — dedup 키를 해시로만 캐시해 메모리를 키당 8바이트로
    /// 억제한다 (충돌 확률은 수백만 키에서도 ~1e-8). 윈도우 앱과 같은 알고리즘.
    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// 잃은 키 목록(keys 등장 순)의 안정 다이제스트.
    private static func lostDigest(_ lost: [UInt64]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for k in lost {
            var v = k.littleEndian
            withUnsafeBytes(of: &v) { raw in
                for b in raw { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
            }
        }
        return h
    }

    /// 기여분을 집계 변수에 합산한다. daily 는 windowKey("yyyy-MM-dd") 이후만.
    private static func addContribution(
        _ c: Contribution, usage: inout TokenUsage,
        models: inout [String: Int], daily: inout [String: TokenUsage],
        dailyByModel: inout [String: [String: TokenUsage]],
        windowKey: String
    ) {
        usage += c.usage
        for (m, v) in c.models { models[m, default: 0] += v }
        for (day, u) in c.daily where day >= windowKey {
            daily[day, default: TokenUsage()] += u
        }
        for (day, byModel) in c.dailyByModel where day >= windowKey {
            for (model, u) in byModel {
                dailyByModel[day, default: [:]][model, default: TokenUsage()] += u
            }
        }
    }

    // MARK: - Claude Code (~/.claude/projects/**/<session>.jsonl)

    /// 한 API 응답의 dedup 단위별 최종 상태 (last-wins).
    private struct ClaudeMessageUsage {
        var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
        var timestamp: Date? = nil
        var model: String? = nil
        var total: Int { input + output + cacheWrite + cacheRead }
    }

    /// assistant 라인의 `message.usage` 를 **(message.id, requestId) 단위로 dedup** 해 합산한다.
    ///
    /// Claude Code 는 한 API 응답을 콘텐츠 블록마다 별도 라인으로 반복 기록하고
    /// (같은 message.id, usage 는 동일하거나 스트리밍 중 증가), 그대로 합산하면
    /// 실사용의 ~2.4배로 부풀려진다(2026-07 실측 6.68B→dedup 2.74B). 재등장 시
    /// usage 는 증가만 하므로 **마지막 값(last-wins)** 을 채택한다. 창(window) 내
    /// 메시지는 마지막 타임스탬프의 로컬 날짜 버킷에 귀속한다.
    static func scanClaudeCode(path: String, windowStart: Date = Self.windowStart()) -> ToolUsageSummary {
        var summary = ToolUsageSummary(tool: .claudeCode)
        guard directoryExists(path) else {
            summary.pathExists = false
            summary.note = "경로를 찾을 수 없습니다"
            return summary
        }

        var usage = TokenUsage()
        var daily: [String: TokenUsage] = [:]
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        var models: [String: Int] = [:]
        var sessions = Set<String>()
        var latest: Date? = nil
        // 파일 간 재등장(--resume 이 과거 대화를 새 세션 파일로 복사) 방지 —
        // 먼저 만난 파일이 이긴다. 키 해시로만 추적한다.
        var seen = Set<UInt64>()
        var visited = Set<String>()
        let windowKey = dayKey(windowStart)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        enumerateFiles(root: URL(fileURLWithPath: path), ext: "jsonl") { url in
            let filePath = url.path
            visited.insert(filePath)
            let mtime = modificationDate(url)
            let fp = FileFP(mtime: mtime, size: fileSize(url))

            var entry = claudeCache[filePath]
            if entry == nil || entry!.fp != fp {
                // 파일이 새로 생겼거나 변경됨 — 전체 파싱.
                guard let (parsed, effective) = parseClaudeFile(
                    url: url, mtime: mtime, windowStart: windowStart, seen: seen
                ) else {
                    claudeCache[filePath] = nil
                    return
                }
                parsed.fp = fp
                claudeCache[filePath] = parsed
                entry = parsed
                addContribution(effective, usage: &usage, models: &models,
                                daily: &daily, dailyByModel: &dailyByModel, windowKey: windowKey)
            } else {
                // 캐시 적중 — 앞 파일에 빼앗긴 키(lost)가 있으면 변형 기여분을 쓴다.
                let e = entry!
                let lost = e.keys.filter { seen.contains($0) }
                if lost.isEmpty {
                    addContribution(e.full, usage: &usage, models: &models,
                                    daily: &daily, dailyByModel: &dailyByModel, windowKey: windowKey)
                } else if let v = e.variants[lostDigest(lost)] {
                    addContribution(v, usage: &usage, models: &models,
                                    daily: &daily, dailyByModel: &dailyByModel, windowKey: windowKey)
                } else {
                    // 이 lost 조합은 처음 — 한 번 재파싱해 변형을 캐시한다
                    // (겹침은 안정적이라 이후 스캔부터는 재파싱 없음).
                    guard let (parsed, effective) = parseClaudeFile(
                        url: url, mtime: mtime, windowStart: windowStart, seen: seen
                    ) else {
                        claudeCache[filePath] = nil
                        return
                    }
                    parsed.fp = fp
                    claudeCache[filePath] = parsed
                    entry = parsed
                    addContribution(effective, usage: &usage, models: &models,
                                    daily: &daily, dailyByModel: &dailyByModel, windowKey: windowKey)
                }
            }
            sessions.insert(url.deletingPathExtension().lastPathComponent)
            for k in entry!.keys { seen.insert(k) }
            bumpLatest(&latest, mtime)
        }

        // 이번 스캔에서 보이지 않은 파일 항목 제거 (삭제된 파일·루트 변경).
        claudeCache = claudeCache.filter { visited.contains($0.key) }

        summary.usage = usage
        summary.daily = daily
        summary.dailyByModel = dailyByModel
        summary.today = daily[dayKey(Date())] ?? TokenUsage()
        summary.models = models
        summary.sessionCount = sessions.count
        summary.lastActivity = latest
        if sessions.isEmpty { summary.note = "세션 로그가 없습니다" }
        return summary
    }

    /// Claude 세션 파일 하나를 파싱해 캐시 항목과, 현재 seen(앞 파일이 가져간
    /// 키) 기준의 실제 기여분(effective)을 돌려준다. 읽기 실패 시 nil.
    private static func parseClaudeFile(
        url: URL, mtime: Date?, windowStart: Date, seen: Set<UInt64>
    ) -> (ClaudeFileEntry, Contribution)? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // 파일이 창 시작 이전에 마지막 수정됐다면 창 내 데이터가 있을 수 없다.
        let mayHaveWindow = (mtime ?? .distantPast) >= windowStart

        // 파일 내 dedup 맵 — 등장 순서를 보존해야 라인 순 last-wins 가 된다.
        var byMessage: [String: ClaudeMessageUsage] = [:]
        var order: [String] = []
        var anonymous = 0  // message.id 없는 라인용 고유 키 시퀀스

        content.enumerateLines { line, _ in
            // 빠른 프리필터: usage 없는 라인은 JSON 파싱 자체를 건너뛴다.
            guard line.contains("\"usage\"") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let u = message["usage"] as? [String: Any]
            else { return }

            let key: String
            if let mid = message["id"] as? String, !mid.isEmpty {
                key = mid + "|" + ((obj["requestId"] as? String) ?? "")
            } else {
                anonymous += 1
                key = "__anon__\(anonymous)"
            }

            var entry = byMessage[key] ?? {
                order.append(key)
                return ClaudeMessageUsage()
            }()
            entry.input = int(u["input_tokens"])
            entry.output = int(u["output_tokens"])
            entry.cacheWrite = int(u["cache_creation_input_tokens"])
            entry.cacheRead = int(u["cache_read_input_tokens"])
            if mayHaveWindow, let ts = parseDate(obj["timestamp"]) { entry.timestamp = ts }
            if let model = message["model"] as? String, !model.isEmpty { entry.model = model }
            byMessage[key] = entry
        }

        let entry = ClaudeFileEntry()
        var effective = Contribution()
        var lost: [UInt64] = []

        for key in order {
            guard let m = byMessage[key] else { continue }
            var isLost = false
            // 익명 키는 파일 로컬이므로 파일 간 dedup 대상에서 제외.
            if !key.hasPrefix("__anon__") {
                let kh = fnv1a(key)
                entry.keys.append(kh)
                if seen.contains(kh) {
                    isLost = true
                    lost.append(kh)
                }
            }
            addClaudeMessage(&entry.full, m, windowStart: windowStart)
            if !isLost { addClaudeMessage(&effective, m, windowStart: windowStart) }
        }
        if !lost.isEmpty { entry.variants[lostDigest(lost)] = effective }
        return (entry, effective)
    }

    /// dedup 된 메시지 하나를 기여분에 누적한다.
    private static func addClaudeMessage(
        _ c: inout Contribution, _ m: ClaudeMessageUsage, windowStart: Date
    ) {
        c.usage.input += m.input
        c.usage.output += m.output
        c.usage.cacheWrite += m.cacheWrite
        c.usage.cacheRead += m.cacheRead
        c.usage.total += m.total

        // 모델별 누적 — "<synthetic>"(내부 합성 응답, 토큰 0)은 제외.
        if m.total > 0, let model = m.model, model != "<synthetic>" {
            c.models[model, default: 0] += m.total
        }

        if let ts = m.timestamp, ts >= windowStart {
            let dayUsage = TokenUsage(
                input: m.input, output: m.output,
                cacheRead: m.cacheRead, cacheWrite: m.cacheWrite,
                reasoning: 0, total: m.total
            )
            let day = dayKey(ts)
            c.daily[day, default: TokenUsage()] += dayUsage
            // 일자×모델 귀속 — "<synthetic>"(토큰 0)은 제외, 모델 미상은 "".
            let model = (m.model == "<synthetic>") ? "" : (m.model ?? "")
            c.dailyByModel[day, default: [:]][model, default: TokenUsage()] += dayUsage
        }
    }

    // MARK: - Codex CLI (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

    /// 각 rollout 파일의 마지막 `token_count` 이벤트가 그 세션의 누적 사용량이다.
    /// 라인마다 더하면 중복 계산되므로 세션별 마지막 스냅샷만 합산한다.
    static func scanCodex(paths: [String], windowStart: Date = Self.windowStart()) -> ToolUsageSummary {
        var summary = ToolUsageSummary(tool: .codex)
        let existingPaths = paths.filter(directoryExists)
        guard !existingPaths.isEmpty else {
            summary.pathExists = false
            summary.note = "경로를 찾을 수 없습니다"
            return summary
        }

        var usage = TokenUsage()
        var daily: [String: TokenUsage] = [:]
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        var models: [String: Int] = [:]
        var sessions = 0
        var latest: Date? = nil
        var visited = Set<String>()
        var seenNames = Set<String>()
        let windowKey = dayKey(windowStart)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        for path in existingPaths {
            enumerateFiles(root: URL(fileURLWithPath: path), ext: "jsonl") { url in
                // 크로스-root 세션 dedup — rollout 파일명(rollout-<ts>-<uuid>.jsonl)은 세션당
                // 전역 유일하다. macOS 는 `~/.codex/sessions` 가 orca 런타임 홈의 **하드링크
                // 서브셋**(같은 inode, 다른 경로)이라 경로 dedup(resolvingSymlinksInPath 은
                // 하드링크를 못 합침)으로는 못 걸러, 두 root 병합 시 공유 세션이 이중 집계된다.
                // 다른 root 에서 같은 파일명을 다시 만나면 스킵한다(first-wins, 내용 동일).
                guard seenNames.insert(url.lastPathComponent).inserted else { return }
                // 같은 물리 파일을 심볼릭 링크·중첩 경로로 두 번 발견해도 한 번만 센다.
                let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard visited.insert(filePath).inserted else { return }
                let mtime = modificationDate(url)
                let fp = FileFP(mtime: mtime, size: fileSize(url))

                var entry = codexCache[filePath]
                if entry == nil || entry!.fp != fp {
                    guard let parsed = parseCodexFile(url: url, mtime: mtime, windowStart: windowStart) else {
                        codexCache[filePath] = nil
                        return
                    }
                    parsed.fp = fp
                    codexCache[filePath] = parsed
                    entry = parsed
                }
                guard let e = entry, e.hasData else { return }

                usage += e.session
                sessions += 1
                if e.session.total > 0 { models[e.model, default: 0] += e.session.total }
                for (day, u) in e.daily where day >= windowKey {
                    daily[day, default: TokenUsage()] += u
                }
                for (day, byModel) in e.dailyByModel where day >= windowKey {
                    for (model, u) in byModel {
                        dailyByModel[day, default: [:]][model, default: TokenUsage()] += u
                    }
                }
                bumpLatest(&latest, mtime)
            }
        }

        // 이번 스캔에서 보이지 않은 파일 항목 제거 (삭제된 파일·루트 변경).
        codexCache = codexCache.filter { visited.contains($0.key) }

        summary.usage = usage
        summary.daily = daily
        summary.dailyByModel = dailyByModel
        summary.today = daily[dayKey(Date())] ?? TokenUsage()
        summary.models = models
        summary.sessionCount = sessions
        summary.lastActivity = latest
        if sessions == 0 { summary.note = "토큰 기록이 있는 세션이 없습니다" }
        return summary
    }

    /// Codex는 호스트 앱이 격리된 CODEX_HOME을 쓰기도 한다. 설정 경로를 우선하고,
    /// 현재 확인된 Orca 런타임 저장소가 존재하면 함께 읽는다.
    private static func codexSessionPaths(primary: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            primary,
            home.appendingPathComponent(
                "Library/Application Support/orca/codex-runtime-home/home/sessions",
                isDirectory: true
            ).path,
        ]
        var seen = Set<String>()
        return candidates.filter { path in
            guard !path.isEmpty else { return false }
            let normalized = URL(fileURLWithPath: path)
                .resolvingSymlinksInPath().standardizedFileURL.path
            return seen.insert(normalized).inserted
        }
    }

    /// rollout 파일 하나를 파싱해 캐시 항목을 만든다. 읽기 실패 시 nil,
    /// token_count 가 없거나 깨진 파일은 hasData=false 로 기억해 재읽기를 피한다.
    private static func parseCodexFile(
        url: URL, mtime: Date?, windowStart: Date
    ) -> CodexFileEntry? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let mayHaveWindow = (mtime ?? .distantPast) >= windowStart

        // 마지막 token_count / turn_context 라인만 보관 (라인마다 파싱하지 않는다).
        // 창 내 파일이면 일자별 귀속용으로 token_count 라인 전체도 모은다.
        var lastTokenLine: String? = nil
        var lastTurnContextLine: String? = nil
        var windowTokenLines: [String] = []
        content.enumerateLines { line, _ in
            if line.contains("\"token_count\"") {
                lastTokenLine = line
                if mayHaveWindow { windowTokenLines.append(line) }
            } else if line.contains("\"turn_context\"") {
                lastTurnContextLine = line
            }
        }

        let entry = CodexFileEntry()
        guard let line = lastTokenLine,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let totalUsage = info["total_token_usage"] as? [String: Any]
        else { return entry }

        let inputTotal = int(totalUsage["input_tokens"])       // 캐시 히트 포함
        let cached = int(totalUsage["cached_input_tokens"])    // input 의 부분집합
        let output = int(totalUsage["output_tokens"])
        let reasoning = int(totalUsage["reasoning_output_tokens"])
        let total = int(totalUsage["total_tokens"])

        // 브레이크다운 합이 total 과 맞도록 캐시분을 input 에서 분리.
        entry.session = TokenUsage(
            input: max(0, inputTotal - cached),
            output: output,
            cacheRead: cached,
            cacheWrite: 0,
            reasoning: reasoning,
            total: total > 0 ? total : (inputTotal + output)
        )
        entry.hasData = true

        // 세션 토큰을 마지막 turn_context 의 모델에 귀속. 구버전 rollout 은
        // turn_context 가 없어 "unknown" 버킷으로 모은다.
        if let tcLine = lastTurnContextLine,
           let tcData = tcLine.data(using: .utf8),
           let tc = try? JSONSerialization.jsonObject(with: tcData) as? [String: Any],
           let tcPayload = tc["payload"] as? [String: Any],
           let m = tcPayload["model"] as? String, !m.isEmpty {
            entry.model = m
        }

        // 일자별: 창 내 token_count 이벤트의 `last_token_usage`(턴 단건)를 각 이벤트
        // 시각의 날짜로 귀속한다 — 자정을 넘긴 세션도 날짜별로 쪼개진다.
        //
        // Σ(턴 단건)이 최종 누적과 다른 파일이 실측으로 존재한다(2026-07, 54개
        // 세션 중 9개, 합계 +1.5% — 중단/재시도 턴의 usage 가 누적 카운터에
        // 반영되지 않는 케이스). 최종 누적이 권위값이므로, 어긋난 파일은 턴
        // 기여분을 비례 스케일링해 Σ(일자 버킷) ≈ 세션 누적으로 정합시킨다.
        var sumTurnTotal = 0
        var turns: [(day: String, usage: TokenUsage)] = []
        for tl in windowTokenLines {
            guard let tData = tl.data(using: .utf8),
                  let tObj = try? JSONSerialization.jsonObject(with: tData) as? [String: Any],
                  let tPayload = tObj["payload"] as? [String: Any],
                  let tInfo = tPayload["info"] as? [String: Any],  // info:null 하트비트 제외
                  let lu = tInfo["last_token_usage"] as? [String: Any]
            else { continue }
            let ti = int(lu["input_tokens"])
            let tCached = int(lu["cached_input_tokens"])
            let tOut = int(lu["output_tokens"])
            let tReason = int(lu["reasoning_output_tokens"])
            let tTotal = int(lu["total_tokens"])
            let turnUsage = TokenUsage(
                input: max(0, ti - tCached),
                output: tOut,
                cacheRead: tCached,
                cacheWrite: 0,
                reasoning: tReason,
                total: tTotal > 0 ? tTotal : (ti + tOut)
            )
            // 스케일 분모는 창 여부와 무관하게 파일의 모든 턴 합.
            sumTurnTotal += turnUsage.total
            guard let ts = parseDate(tObj["timestamp"]), ts >= windowStart else { continue }
            turns.append((dayKey(ts), turnUsage))
        }
        let factor: Double = (sumTurnTotal > 0 && entry.session.total > 0)
            ? Double(entry.session.total) / Double(sumTurnTotal)
            : 1
        for (day, raw) in turns {
            let turnUsage = abs(factor - 1) > 0.0001 ? scaledUsage(raw, by: factor) : raw
            entry.daily[day, default: TokenUsage()] += turnUsage
            entry.dailyByModel[day, default: [:]][entry.model, default: TokenUsage()] += turnUsage
        }
        return entry
    }

    /// 각 축을 비율로 줄이거나 늘린(반올림) 사본 — Codex 일자 버킷 보정용.
    private static func scaledUsage(_ u: TokenUsage, by factor: Double) -> TokenUsage {
        func s(_ n: Int) -> Int { Int((Double(n) * factor).rounded()) }
        return TokenUsage(
            input: s(u.input), output: s(u.output),
            cacheRead: s(u.cacheRead), cacheWrite: s(u.cacheWrite),
            reasoning: s(u.reasoning), total: s(u.total)
        )
    }

    // MARK: - OpenCode (신버전: <data>/opencode.db · 구버전: <data>/storage/message/**/*.json)

    /// OpenCode 는 2025 말부터 Drizzle SQLite(`opencode.db`)에 메시지를 저장한다.
    /// (그 전 버전은 파일 기반 `storage/message/`.) 둘 다 assistant 메시지의
    /// `tokens` / `cost` / `modelID` 를 합산하며, db 가 있으면 db 를 우선한다
    /// (마이그레이션 후 남은 파일 storage 와의 이중 계산 방지).
    static func scanOpenCode(path: String, windowStart: Date = Self.windowStart()) -> ToolUsageSummary {
        var summary = ToolUsageSummary(tool: .openCode)
        let fm = FileManager.default

        // .db 파일을 직접 가리키면 SQLite 로 스캔한다.
        if path.hasSuffix(".db") {
            guard fm.fileExists(atPath: path) else {
                summary.pathExists = false
                summary.note = "경로를 찾을 수 없습니다"
                return summary
            }
            return scanOpenCodeDB(dbPath: path, windowStart: windowStart)
        }

        guard directoryExists(path) else {
            summary.pathExists = false
            summary.note = "경로를 찾을 수 없습니다"
            return summary
        }

        // 신버전 SQLite 가 있으면 그것을 단일 소스로 사용.
        let dbPath = (path as NSString).appendingPathComponent("opencode.db")
        if fm.fileExists(atPath: dbPath) {
            return scanOpenCodeDB(dbPath: dbPath, windowStart: windowStart)
        }

        // message 디렉토리 후보를 순서대로 탐색 (구버전 파일 storage).
        let base = URL(fileURLWithPath: path)
        let candidates = [
            base.appendingPathComponent("storage/message"),
            base.appendingPathComponent("message"),
            base, // 이미 message 폴더를 가리키는 경우
        ]
        guard let messageDir = candidates.first(where: { directoryExists($0.path) }) else {
            summary.note = "opencode.db / storage/message 가 없습니다 (미사용?)"
            return summary
        }

        var usage = TokenUsage()
        var daily: [String: TokenUsage] = [:]
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        var dailyCostByModel: [String: [String: Double]] = [:]
        var models: [String: Int] = [:]
        var cost: Double = 0
        var sessions = Set<String>()
        var latest: Date? = nil

        enumerateFiles(root: messageDir, ext: "json") { url in
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            guard (obj["role"] as? String) == "assistant",
                  let tokens = obj["tokens"] as? [String: Any]
            else { return }

            let input = int(tokens["input"])
            let output = int(tokens["output"])
            let reasoning = int(tokens["reasoning"])
            var cacheRead = 0
            var cacheWrite = 0
            if let cache = tokens["cache"] as? [String: Any] {
                cacheRead = int(cache["read"])
                cacheWrite = int(cache["write"])
            }

            let messageUsage = TokenUsage(
                input: input, output: output,
                cacheRead: cacheRead, cacheWrite: cacheWrite,
                reasoning: reasoning,
                total: input + output + cacheRead + cacheWrite
            )
            usage += messageUsage

            // 모델별 누적 + API 비용(USD) — OpenCode 는 메시지에 둘 다 기록한다.
            let modelID = (obj["modelID"] as? String) ?? ""
            if messageUsage.total > 0, !modelID.isEmpty {
                models[modelID, default: 0] += messageUsage.total
            }
            var msgCost: Double = 0
            if let c = obj["cost"] as? Double { msgCost = c }
            else if let c = obj["cost"] as? NSNumber { msgCost = c.doubleValue }
            cost += msgCost

            // 오늘 여부: time.created(epoch ms) 우선, 없으면 파일 수정시각.
            var when: Date? = nil
            if let time = obj["time"] as? [String: Any] {
                let createdMs = int(time["created"])
                if createdMs > 0 { when = Date(timeIntervalSince1970: Double(createdMs) / 1000) }
            }
            let mtime = modificationDate(url)
            if when == nil { when = mtime }
            if let when, when >= windowStart {
                let day = dayKey(when)
                daily[day, default: TokenUsage()] += messageUsage
                dailyByModel[day, default: [:]][modelID, default: TokenUsage()] += messageUsage
                if msgCost != 0 {
                    dailyCostByModel[day, default: [:]][modelID, default: 0] += msgCost
                }
            }

            // 세션 ID = 상위 폴더명 (storage/message/<sessionID>/<messageID>.json).
            sessions.insert(url.deletingLastPathComponent().lastPathComponent)
            bumpLatest(&latest, mtime)
        }

        summary.usage = usage
        summary.daily = daily
        summary.dailyByModel = dailyByModel
        summary.dailyCostByModel = dailyCostByModel
        summary.today = daily[dayKey(Date())] ?? TokenUsage()
        summary.models = models
        summary.costUSD = cost
        summary.sessionCount = sessions.count
        summary.lastActivity = latest
        if sessions.isEmpty { summary.note = "사용 기록이 없습니다" }
        return summary
    }

    /// 신버전 OpenCode SQLite(`opencode.db`) 스캔 — `message` 테이블의 `data` JSON 에서
    /// assistant 메시지의 토큰·비용·모델을 집계한다 (tokenova 와 동일 스키마 해석).
    /// 실행 중 잠금을 피하려 read-only + immutable 로 연다.
    private static func scanOpenCodeDB(dbPath: String, windowStart: Date) -> ToolUsageSummary {
        var summary = ToolUsageSummary(tool: .openCode)
        guard let encoded = dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            summary.note = "경로 인코딩 실패"
            return summary
        }

        var db: OpaquePointer?
        let uri = "file:\(encoded)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db
        else {
            summary.note = "opencode.db 를 열 수 없습니다"
            if db != nil { sqlite3_close(db) }
            return summary
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let sql = """
        SELECT json_extract(data, '$.sessionID'),
               time_created,
               json_extract(data, '$.modelID'),
               json_extract(data, '$.cost'),
               json_extract(data, '$.tokens.input'),
               json_extract(data, '$.tokens.output'),
               json_extract(data, '$.tokens.reasoning'),
               json_extract(data, '$.tokens.cache.read'),
               json_extract(data, '$.tokens.cache.write')
          FROM message
         WHERE json_extract(data, '$.role') = 'assistant'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            summary.note = "opencode.db message 조회 실패 (스키마 상이?)"
            return summary
        }
        defer { sqlite3_finalize(stmt) }

        var usage = TokenUsage()
        var daily: [String: TokenUsage] = [:]
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        var dailyCostByModel: [String: [String: Double]] = [:]
        var models: [String: Int] = [:]
        var cost: Double = 0
        var sessions = Set<String>()
        var latest: Date? = nil

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = sqlite3_column_text(stmt, 0) { sessions.insert(String(cString: s)) }
            let createdMs = sqlite3_column_int64(stmt, 1)
            let input = Int(sqlite3_column_int64(stmt, 4))
            let output = Int(sqlite3_column_int64(stmt, 5))
            let reasoning = Int(sqlite3_column_int64(stmt, 6))
            let cacheRead = Int(sqlite3_column_int64(stmt, 7))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 8))

            let messageUsage = TokenUsage(
                input: input, output: output,
                cacheRead: cacheRead, cacheWrite: cacheWrite,
                reasoning: reasoning,
                total: input + output + cacheRead + cacheWrite
            )
            usage += messageUsage
            let msgCost = sqlite3_column_double(stmt, 3)
            cost += msgCost

            var model = ""
            if let m = sqlite3_column_text(stmt, 2) { model = String(cString: m) }
            if messageUsage.total > 0, !model.isEmpty { models[model, default: 0] += messageUsage.total }

            if createdMs > 0 {
                let when = Date(timeIntervalSince1970: Double(createdMs) / 1000)
                if when >= windowStart {
                    let day = dayKey(when)
                    daily[day, default: TokenUsage()] += messageUsage
                    dailyByModel[day, default: [:]][model, default: TokenUsage()] += messageUsage
                    if msgCost != 0 {
                        dailyCostByModel[day, default: [:]][model, default: 0] += msgCost
                    }
                }
                bumpLatest(&latest, when)
            }
        }

        summary.usage = usage
        summary.daily = daily
        summary.dailyByModel = dailyByModel
        summary.dailyCostByModel = dailyCostByModel
        summary.today = daily[dayKey(Date())] ?? TokenUsage()
        summary.models = models
        summary.costUSD = cost
        summary.sessionCount = sessions.count
        summary.lastActivity = latest
        if usage.total == 0 { summary.note = "opencode.db 에 사용 기록이 없습니다" }
        return summary
    }

    // MARK: - Cursor (~/Library/Application Support/Cursor/.../state.vscdb)

    /// Cursor(VS Code fork)의 채팅 SQLite(`state.vscdb`)에서 토큰을 집계한다.
    ///
    /// `cursorDiskKV` 의 `bubbleId:<대화>:<버블>` 값에 `tokenCount.{inputTokens,
    /// outputTokens}` 가 있다(캐시 분해는 없어 cache=0). 버블에 시각이 없으므로
    /// 부모 대화(`composerData:<대화>`)의 `createdAt` 로 일자를 근사한다.
    /// 실행 중 잠금을 피하려 read-only + immutable 로 연다.
    static func scanCursor(path: String, windowStart: Date = Self.windowStart()) -> ToolUsageSummary {
        var summary = ToolUsageSummary(tool: .cursor)
        guard FileManager.default.fileExists(atPath: path) else {
            summary.pathExists = false
            summary.note = "state.vscdb 를 찾을 수 없습니다"
            return summary
        }
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            summary.note = "경로 인코딩 실패"
            return summary
        }

        var db: OpaquePointer?
        let uri = "file:\(encoded)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db
        else {
            summary.note = "state.vscdb 를 열 수 없습니다"
            if db != nil { sqlite3_close(db) }
            return summary
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // 1) 토큰이 있는 버블만 조회 (json_extract 로 필드만 뽑아 blob 파싱 회피).
        let bubbleSQL = """
        SELECT key,
               json_extract(value, '$.tokenCount.inputTokens'),
               json_extract(value, '$.tokenCount.outputTokens')
          FROM cursorDiskKV
         WHERE key LIKE 'bubbleId:%'
           AND (json_extract(value, '$.tokenCount.inputTokens') > 0
                OR json_extract(value, '$.tokenCount.outputTokens') > 0)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, bubbleSQL, -1, &stmt, nil) == SQLITE_OK else {
            summary.note = "cursorDiskKV 조회 실패 (형식 상이?)"
            return summary
        }
        var bubbles: [(composer: String, input: Int, output: Int)] = []
        var composerIds = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: keyC)  // bubbleId:<composer>:<bubble>
            let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let composer = String(parts[1])
            let input = Int(sqlite3_column_int64(stmt, 1))
            let output = Int(sqlite3_column_int64(stmt, 2))
            bubbles.append((composer, input, output))
            composerIds.insert(composer)
        }
        sqlite3_finalize(stmt)

        guard !bubbles.isEmpty else {
            summary.note = "토큰 기록이 있는 대화가 없습니다"
            return summary
        }

        // 2) 대화별 생성일 — 토큰 있는 대화만 키 지정(PK) 조회로 빠르게.
        var composerDay: [String: String] = [:]
        let dateSQL = "SELECT json_extract(value, '$.createdAt') FROM cursorDiskKV WHERE key = ?"
        var dstmt: OpaquePointer?
        if sqlite3_prepare_v2(db, dateSQL, -1, &dstmt, nil) == SQLITE_OK {
            for cid in composerIds {
                sqlite3_reset(dstmt)
                sqlite3_clear_bindings(dstmt)
                _ = ("composerData:\(cid)").withCString {
                    sqlite3_bind_text(dstmt, 1, $0, -1, SQLITE_TRANSIENT)
                }
                if sqlite3_step(dstmt) == SQLITE_ROW {
                    let ms = sqlite3_column_int64(dstmt, 0)
                    if ms > 0 {
                        composerDay[cid] = dayKey(Date(timeIntervalSince1970: Double(ms) / 1000))
                    }
                }
            }
        }
        sqlite3_finalize(dstmt)

        // 3) 집계: all-time usage + 창 내 일자별. cache 는 없으므로 0.
        let windowStartKey = dayKey(windowStart)  // "yyyy-MM-dd" 문자열 비교 = 시간순
        var usage = TokenUsage()
        var daily: [String: TokenUsage] = [:]
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        var latestDay: String? = nil
        for b in bubbles {
            let u = TokenUsage(
                input: b.input, output: b.output,
                cacheRead: 0, cacheWrite: 0, reasoning: 0,
                total: b.input + b.output
            )
            usage += u
            if let day = composerDay[b.composer] {
                if day >= windowStartKey {
                    daily[day, default: TokenUsage()] += u
                    // DB 버블은 모델 정보가 없어 미상("") 버킷에 귀속.
                    dailyByModel[day, default: [:]]["", default: TokenUsage()] += u
                }
                if latestDay == nil || day > latestDay! { latestDay = day }
            }
        }

        summary.usage = usage
        summary.daily = daily
        summary.dailyByModel = dailyByModel
        summary.today = daily[dayKey(Date())] ?? TokenUsage()
        summary.sessionCount = composerIds.count
        if let latestDay, let d = dayDate(latestDay) { summary.lastActivity = d }
        return summary
    }

    /// "yyyy-MM-dd" → 로컬 자정 Date (lastActivity 표시용, 대략).
    private static func dayDate(_ key: String) -> Date? {
        dayFormatter.date(from: key)
    }

    // MARK: - Gemini CLI (~/.gemini/tmp/<hash>/chats/session-*.json|jsonl)

    /// 델타 보정 후 한 Gemini 메시지의 정규화된 기여분.
    private struct GeminiMsg {
        var timestamp: Date?
        var model: String
        var usage: TokenUsage
    }

    /// 파싱 단계의 Gemini 메시지 원본 토큰(세션 내 누적값) — 델타 보정 전.
    private struct GeminiRaw {
        var timestamp: Date?
        var model: String
        var input: Int      // tokens.input (세션 누적)
        var cached: Int     // tokens.cached (세션 누적)
        var output: Int     // tokens.output + tokens.thoughts (메시지별)
        var reasoning: Int  // tokens.thoughts (메시지별)
    }

    /// Gemini CLI 세션을 스캔한다. 각 파일은 단일 JSON 오브젝트
    /// (`{sessionId, messages:[...]}`) 또는 JSONL(라인별 레코드)이다.
    /// `tokens.input`/`tokens.cached` 는 세션 내 **누적값**이라 메시지 순서대로 직전과의
    /// 델타를 취한다(음수면 리셋으로 보고 raw 사용). output/thoughts 는 메시지별 그대로.
    /// 매핑: input=Δinput, cacheRead=Δcached, output=output+thoughts, reasoning=thoughts.
    static func scanGemini(path: String, windowStart: Date = Self.windowStart()) -> ToolUsageSummary {
        var summary = ToolUsageSummary(tool: .gemini)
        guard directoryExists(path) else {
            summary.pathExists = false
            summary.note = "경로를 찾을 수 없습니다"
            return summary
        }

        var usage = TokenUsage()
        var daily: [String: TokenUsage] = [:]
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        var models: [String: Int] = [:]
        var sessions = Set<String>()
        var latest: Date? = nil

        let root = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        if let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in en {
                let ext = url.pathExtension
                guard ext == "json" || ext == "jsonl",
                      url.lastPathComponent.hasPrefix("session-")
                else { continue }
                guard let parsed = parseGeminiFile(url: url) else { continue }
                sessions.insert(parsed.sessionId)
                for m in parsed.messages {
                    usage += m.usage
                    if m.usage.total > 0, !m.model.isEmpty {
                        models[m.model, default: 0] += m.usage.total
                    }
                    if let ts = m.timestamp, ts >= windowStart {
                        let day = dayKey(ts)
                        daily[day, default: TokenUsage()] += m.usage
                        dailyByModel[day, default: [:]][m.model, default: TokenUsage()] += m.usage
                    }
                }
                bumpLatest(&latest, modificationDate(url))
            }
        }

        summary.usage = usage
        summary.daily = daily
        summary.dailyByModel = dailyByModel
        summary.today = daily[dayKey(Date())] ?? TokenUsage()
        summary.models = models
        summary.sessionCount = sessions.count
        summary.lastActivity = latest
        if sessions.isEmpty { summary.note = "세션 로그가 없습니다" }
        return summary
    }

    /// Gemini 세션 파일 하나를 (sessionId, 델타 보정된 메시지)로 파싱. 실패 시 nil.
    private static func parseGeminiFile(url: URL) -> (sessionId: String, messages: [GeminiMsg])? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // 단일 JSON 오브젝트 형태 우선.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["sessionId"] != nil || obj["messages"] is [Any] {
            guard let sid = obj["sessionId"] as? String, !sid.isEmpty else { return nil }
            var raws: [GeminiRaw] = []
            if let arr = obj["messages"] as? [[String: Any]] {
                for m in arr { if let r = geminiRaw(m) { raws.append(r) } }
            }
            return (sid, applyGeminiDeltas(raws))
        }

        // JSONL 형태 — 라인별 레코드, 같은 메시지 id 는 last-wins.
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        var sessionId = ""
        var byId: [String: GeminiRaw] = [:]
        var order: [String] = []
        var anon = 0
        content.enumerateLines { line, _ in
            guard let ld = line.data(using: .utf8),
                  let rec = try? JSONSerialization.jsonObject(with: ld) as? [String: Any]
            else { return }
            if sessionId.isEmpty, let sid = rec["sessionId"] as? String, !sid.isEmpty {
                sessionId = sid
            }
            guard let type = rec["type"] as? String, type == "user" || type == "gemini",
                  let r = geminiRaw(rec)
            else { return }
            if let id = rec["id"] as? String, !id.isEmpty {
                if byId[id] == nil { order.append(id) }
                byId[id] = r
            } else {
                anon += 1
                let k = "__anon__\(anon)"
                order.append(k)
                byId[k] = r
            }
        }
        guard !sessionId.isEmpty else { return nil }
        return (sessionId, applyGeminiDeltas(order.compactMap { byId[$0] }))
    }

    /// 세션 내 누적 input/cached 를 메시지 순서대로 델타로 변환한다.
    /// prev 는 tokens 있는 메시지(=raws 원소)마다 전진하고, 음수 델타는 리셋으로 보고
    /// raw 값을 쓴다. output/thoughts 는 그대로. (agentsview applyGeminiCumulativeDeltas)
    private static func applyGeminiDeltas(_ raws: [GeminiRaw]) -> [GeminiMsg] {
        var prevInput = 0
        var prevCached = 0
        var out: [GeminiMsg] = []
        out.reserveCapacity(raws.count)
        for r in raws {
            var inputDelta = r.input - prevInput
            if inputDelta < 0 { inputDelta = r.input }
            var cachedDelta = r.cached - prevCached
            if cachedDelta < 0 { cachedDelta = r.cached }
            prevInput = r.input
            prevCached = r.cached
            let usage = TokenUsage(
                input: inputDelta, output: r.output,
                cacheRead: cachedDelta, cacheWrite: 0,
                reasoning: r.reasoning,
                total: inputDelta + r.output + cachedDelta
            )
            out.append(GeminiMsg(timestamp: r.timestamp, model: r.model, usage: usage))
        }
        return out
    }

    /// Gemini 메시지 dict → 원본 토큰(누적, 델타 보정 전). `tokens` 없으면(사용자 등) nil.
    private static func geminiRaw(_ m: [String: Any]) -> GeminiRaw? {
        guard let tokens = m["tokens"] as? [String: Any] else { return nil }
        return GeminiRaw(
            timestamp: parseDate(m["timestamp"]),
            model: (m["model"] as? String) ?? "",
            input: int(tokens["input"]),
            cached: int(tokens["cached"]),
            output: int(tokens["output"]) + int(tokens["thoughts"]),
            reasoning: int(tokens["thoughts"])
        )
    }

    // MARK: - Qwen Code (~/.qwen/projects/**/*.jsonl)

    /// Qwen Code 세션(Claude Code 와 같은 projects 레이아웃)을 스캔한다.
    /// `type==assistant` 라인의 `usageMetadata` 를 라인 단위로 그대로 합산한다
    /// (한 턴의 tool-call 반복 라인마다 usage 가 반복돼도 각 호출이 별개 과금).
    /// 매핑: cacheRead=`cachedContentTokenCount`, input=`promptTokenCount - cached`,
    /// output=`candidatesTokenCount + thoughtsTokenCount`, reasoning=`thoughtsTokenCount`.
    static func scanQwen(path: String, windowStart: Date = Self.windowStart()) -> ToolUsageSummary {
        var summary = ToolUsageSummary(tool: .qwen)
        guard directoryExists(path) else {
            summary.pathExists = false
            summary.note = "경로를 찾을 수 없습니다"
            return summary
        }

        var usage = TokenUsage()
        var daily: [String: TokenUsage] = [:]
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        var models: [String: Int] = [:]
        var sessions = Set<String>()
        var latest: Date? = nil

        enumerateFiles(root: URL(fileURLWithPath: path), ext: "jsonl") { url in
            sessions.insert(url.path)  // 고유 .jsonl 파일 = 세션
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            content.enumerateLines { line, _ in
                guard line.contains("\"usageMetadata\""),
                      let ld = line.data(using: .utf8),
                      let rec = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                      (rec["type"] as? String) == "assistant",
                      let meta = rec["usageMetadata"] as? [String: Any]
                else { return }

                let prompt = int(meta["promptTokenCount"])
                let candidates = int(meta["candidatesTokenCount"])
                let cached = int(meta["cachedContentTokenCount"])
                let thoughts = int(meta["thoughtsTokenCount"])
                let input = max(0, prompt - cached)
                let output = candidates + thoughts
                let u = TokenUsage(
                    input: input, output: output,
                    cacheRead: cached, cacheWrite: 0,
                    reasoning: thoughts,
                    total: input + output + cached
                )
                usage += u

                // 모델 = 라인의 model(없으면 message.model, 그래도 없으면 "unknown").
                var model = (rec["model"] as? String) ?? ""
                if model.isEmpty, let msg = rec["message"] as? [String: Any] {
                    model = (msg["model"] as? String) ?? ""
                }
                if model.isEmpty { model = "unknown" }
                if u.total > 0 { models[model, default: 0] += u.total }

                if let ts = parseDate(rec["timestamp"]), ts >= windowStart {
                    let day = dayKey(ts)
                    daily[day, default: TokenUsage()] += u
                    dailyByModel[day, default: [:]][model, default: TokenUsage()] += u
                }
            }
            bumpLatest(&latest, modificationDate(url))
        }

        summary.usage = usage
        summary.daily = daily
        summary.dailyByModel = dailyByModel
        summary.today = daily[dayKey(Date())] ?? TokenUsage()
        summary.models = models
        summary.sessionCount = sessions.count
        summary.lastActivity = latest
        if usage.total == 0 { summary.note = "사용 기록이 없습니다" }
        return summary
    }

    // MARK: - Copilot CLI (~/.copilot/session-state/<uuid>.jsonl | <uuid>/events.jsonl)

    /// Copilot CLI 세션을 스캔한다. `session.shutdown` 이벤트의 `modelMetrics` 만 사용:
    /// 모델키→`usage:{inputTokens,cacheReadTokens,cacheWriteTokens,outputTokens,reasoningTokens}`.
    /// input=`max(inputTokens - cacheRead - cacheWrite, 0)`(inputTokens 는 캐시 포함 총량).
    /// 레이아웃 2종(`<uuid>.jsonl` 구 / `<uuid>/events.jsonl` 신)은 uuid 로 dedup(신형 우선).
    static func scanCopilot(path: String, windowStart: Date = Self.windowStart()) -> ToolUsageSummary {
        var summary = ToolUsageSummary(tool: .copilot)
        let fm = FileManager.default
        guard directoryExists(path) else {
            summary.pathExists = false
            summary.note = "경로를 찾을 수 없습니다"
            return summary
        }

        // uuid → 세션 파일. 신형(events.jsonl) 이 있으면 구형 flat 파일보다 우선.
        var files: [String: URL] = [:]
        let root = URL(fileURLWithPath: path)
        let entries = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue {
                let events = entry.appendingPathComponent("events.jsonl")
                if fm.fileExists(atPath: events.path) {
                    files[entry.lastPathComponent] = events  // 신형 우선
                }
            } else if entry.pathExtension == "jsonl" {
                let uuid = entry.deletingPathExtension().lastPathComponent
                if files[uuid] == nil { files[uuid] = entry }  // 신형이 이미 있으면 유지
            }
        }

        var usage = TokenUsage()
        var daily: [String: TokenUsage] = [:]
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        var models: [String: Int] = [:]
        var sessions = 0
        var latest: Date? = nil

        for (_, url) in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var sessionHadData = false
            content.enumerateLines { line, _ in
                guard line.contains("session.shutdown"),
                      let ld = line.data(using: .utf8),
                      let rec = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                      (rec["type"] as? String) == "session.shutdown",
                      let dataObj = rec["data"] as? [String: Any],
                      let metrics = dataObj["modelMetrics"] as? [String: Any]
                else { return }
                let ts = parseDate(rec["timestamp"])
                let day = ts.map(dayKey)

                for (modelKey, value) in metrics {
                    guard let entry = value as? [String: Any],
                          let u = entry["usage"] as? [String: Any] else { continue }
                    let totalInput = int(u["inputTokens"])   // 캐시 포함 총량
                    let cacheRead = int(u["cacheReadTokens"])
                    let cacheWrite = int(u["cacheWriteTokens"])
                    let output = int(u["outputTokens"])
                    let reasoning = int(u["reasoningTokens"])
                    let input = max(0, totalInput - cacheRead - cacheWrite)
                    if input == 0 && output == 0 && cacheRead == 0
                        && cacheWrite == 0 && reasoning == 0 { continue }

                    let mu = TokenUsage(
                        input: input, output: output,
                        cacheRead: cacheRead, cacheWrite: cacheWrite,
                        reasoning: reasoning,
                        total: input + output + cacheRead + cacheWrite
                    )
                    let model = normalizeCopilotModel(modelKey)
                    usage += mu
                    sessionHadData = true
                    if mu.total > 0 { models[model, default: 0] += mu.total }
                    if let day, let ts, ts >= windowStart {
                        daily[day, default: TokenUsage()] += mu
                        dailyByModel[day, default: [:]][model, default: TokenUsage()] += mu
                    }
                }
            }
            if sessionHadData { sessions += 1 }
            bumpLatest(&latest, modificationDate(url))
        }

        summary.usage = usage
        summary.daily = daily
        summary.dailyByModel = dailyByModel
        summary.today = daily[dayKey(Date())] ?? TokenUsage()
        summary.models = models
        summary.sessionCount = sessions
        summary.lastActivity = latest
        if usage.total == 0 { summary.note = "사용 기록이 없습니다" }
        return summary
    }

    /// Copilot 모델 ID 정규화 — `claude-` 계열만 `.`→`-` (claude-sonnet-4.6→claude-sonnet-4-6).
    /// 그 외(gpt-5.4 등)는 요율표가 이미 점을 쓰므로 그대로 둔다.
    private static func normalizeCopilotModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? model.replacingOccurrences(of: ".", with: "-") : model
    }

    // MARK: - 전체 스캔

    /// 로컬 자정(오늘의 시작).
    static func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    /// 스캔 창의 시작(로컬 자정) — 오늘 포함 최근 scanWindowDays 일. daily 버킷 기준.
    static func windowStart() -> Date {
        Calendar.current.date(
            byAdding: .day, value: -(scanWindowDays - 1), to: startOfToday()
        ) ?? startOfToday()
    }

    /// 최근 N일 창의 시작(로컬 자정) — 오늘 포함 최근 reportWindowDays 일.
    static func reportWindowStart() -> Date {
        Calendar.current.date(
            byAdding: .day, value: -(reportWindowDays - 1), to: startOfToday()
        ) ?? startOfToday()
    }

    /// 최근 N일 창 시작 일자 키("yyyy-MM-dd") — daily 를 7일로 슬라이스할 때 비교용.
    static func reportWindowStartKey() -> String { dayKey(reportWindowStart()) }

    /// 일곱 도구를 순서대로 스캔해 요약 배열을 돌려준다. (백그라운드에서 호출)
    static func scanAll(
        claude: String, codex: String, openCode: String, cursor: String,
        gemini: String, qwen: String, copilot: String
    ) -> [ToolUsageSummary] {
        let start = windowStart()
        let day = dayKey(start)
        let codexPaths = codexSessionPaths(primary: codex)
        let codexCachePath = codexPaths.joined(separator: "\n")
        // includeAllFiles: 확장자가 .jsonl 하나가 아닌 소스(디렉토리 트리에 .db/.json 혼재)는
        // 시그니처에 모든 파일을 포함해 변경을 감지한다.
        let sources: [(AITool, String, Bool)] = [
            (.claudeCode, claude, false),
            (.codex, codexCachePath, false),
            (.openCode, openCode, true),
            (.cursor, cursor, true),
            (.gemini, gemini, true),     // .json + .jsonl 혼재
            (.qwen, qwen, false),        // .jsonl 트리
            (.copilot, copilot, false),  // .jsonl (flat + events.jsonl)
        ]
        var cache = UsageScanCache.load()
        var results: [ToolUsageSummary] = []

        for (tool, path, includeAllFiles) in sources {
            let signature = tool == .codex
                ? UsageScanCache.sourceSignature(paths: codexPaths, includeAllFiles: false)
                : UsageScanCache.sourceSignature(path: path, includeAllFiles: includeAllFiles)
            if let entry = cache[tool.rawValue], entry.path == path,
               entry.signature == signature, entry.windowDay == day {
                results.append(entry.summary)
                continue
            }

            let summary: ToolUsageSummary
            switch tool {
            case .claudeCode: summary = scanClaudeCode(path: path, windowStart: start)
            case .codex: summary = scanCodex(paths: codexPaths, windowStart: start)
            case .openCode: summary = scanOpenCode(path: path, windowStart: start)
            case .cursor: summary = scanCursor(path: path, windowStart: start)
            case .gemini: summary = scanGemini(path: path, windowStart: start)
            case .qwen: summary = scanQwen(path: path, windowStart: start)
            case .copilot: summary = scanCopilot(path: path, windowStart: start)
            }
            cache[tool.rawValue] = UsageScanCache.Entry(
                path: path, signature: signature, windowDay: day, summary: summary
            )
            results.append(summary)
        }

        UsageScanCache.save(cache)
        return results
    }
}

/// 앱 재실행 사이에도 사용량 요약을 재사용하는 영속 캐시.
/// 파일 본문은 fingerprint가 바뀐 도구에서만 다시 읽는다.
private enum UsageScanCache {
    struct Entry: Codable {
        let path: String
        let signature: String
        let windowDay: String
        let summary: ToolUsageSummary
    }

    private static var file: URL {
        AmonPaths.cache.appendingPathComponent("usage-scan.json")
    }

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? AmonJSON.decoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    static func save(_ entries: [String: Entry]) {
        guard let data = try? AmonJSON.encoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: AmonPaths.cache, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func sourceSignature(path: String, includeAllFiles: Bool) -> String {
        sourceSignature(paths: [path], includeAllFiles: includeAllFiles)
    }

    static func sourceSignature(paths: [String], includeAllFiles: Bool) -> String {
        let parts = paths.flatMap { signatureParts(path: $0, includeAllFiles: includeAllFiles) }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.sorted().joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func signatureParts(path: String, includeAllFiles: Bool) -> [String] {
        guard !path.isEmpty else { return ["empty"] }
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var parts: [String] = []
        if let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in en {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                if !includeAllFiles && file.pathExtension != "jsonl" { continue }
                parts.append(signaturePart(file, values: values))
            }
        } else if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            parts.append(signaturePart(url, values: values))
        }
        return parts
    }

    private static func signaturePart(_ url: URL, values: URLResourceValues?) -> String {
        let size = values?.fileSize ?? -1
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(mtime)"
    }
}
