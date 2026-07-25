import Foundation

/// 종료된 세션 기록을 모아 로컬 저장소에 적재하고, 새로 생긴 기록을 알린다.
///
/// `LiveActivityManager` 와 같은 형태(자체 타이머 + onChanged 훅)지만 주기가 길다
/// — 기록은 실시간 데이터가 아니고, Codex rollout 스캔이 파일을 많이 읽는다.
@MainActor
final class SessionHistoryManager: ObservableObject {
    /// 종료 시각 내림차순 세션 기록(로컬 저장소 전체).
    @Published private(set) var records: [SessionRecord] = []
    @Published private(set) var isRefreshing = false

    /// 직전 갱신 대비 새로 생기거나 바뀐 기록만 로컬 SQLite 미러에 전달한다.
    var onChanged: (([SessionRecord]) -> Void)?

    /// 세션 로그 루트 — AppState 가 설정값으로 채워 준다(설정 변경 시 갱신).
    var claudePath: String = ""
    var codexPath: String = ""
    /// Cursor 전역 state.vscdb 경로 — 로그 디렉토리가 아니라 SQLite 파일 하나다.
    var cursorPath: String = ""

    private var autoTask: Task<Void, Never>?
    /// 갱신 주기 — 60초.
    private let interval: TimeInterval = 60
    /// live 세션의 종료 전환을 놓치지 않도록 캐시를 최대 15분만 신뢰한다.
    private let scanCacheTTL: TimeInterval = 15 * 60
    /// 이미 알린 기록(id → 값). 값이 바뀐 것만 다시 알린다.
    private var known: [String: SessionRecord] = [:]

    /// 즉시 1회 갱신 후 주기 타이머를 건다. 중복 시작은 무시.
    func start() {
        guard autoTask == nil else { return }
        autoTask = Task { [weak self] in
            guard let interval = self?.interval else { return }
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.refresh()
            }
        }
    }

    func stop() {
        autoTask?.cancel()
        autoTask = nil
    }

    /// pending 적재 + 좀비 세션 회수 + Codex 스캔 → 저장소 갱신 → 변경분 통지.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let claudePath = self.claudePath
        let codexPath = self.codexPath
        let cursorPath = self.cursorPath
        let cacheTTL = scanCacheTTL

        // Cursor 세션 토큰 추정용 CSV 이벤트 — TTL(5분)이 지난 경우에만 네트워크를
        // 친다. 실패해도 디스크 캐시의 직전 이벤트로 추정이 유지된다.
        if CursorStateDB.resolveGlobalDB(from: cursorPath) != nil {
            await CursorSessionTokens.refreshIfStale()
        }

        let loaded = await Task.detached(priority: .utility) { () -> [SessionRecord] in
            // SessionEnd 를 못 받고 죽은 세션을 먼저 pending 으로 회수한다.
            SessionHistoryScanner.sweepStaleLiveSessions()

            // 원본 로그가 변하지 않았고 캐시가 신선하면 JSONL 본문 파싱을 생략한다.
            // pending 은 훅이 새로 남겼을 수 있으므로 캐시 적중 여부와 관계없이 읽는다.
            if let cache = SessionHistoryCache.load(),
               Date().timeIntervalSince(cache.generatedAt) < cacheTTL,
               SessionHistoryCache.matches(
                   cache, claudePath: claudePath, codexPath: codexPath, cursorPath: cursorPath
               ) {
                let pending = SessionHistoryScanner.ingestPending()
                let merged = SessionHistoryStore.upsert(cache.records + pending)
                if !pending.isEmpty {
                    SessionHistoryCache.save(
                        records: merged,
                        claudePath: claudePath, codexPath: codexPath, cursorPath: cursorPath
                    )
                }
                return merged
            }

            // 로그 백필을 먼저 넣고 pending 을 나중에 넣는다 — 같은 세션이면
            // 훅이 준 정확한 종료 시각(pending)이 upsert 에서 이기게 된다.
            var fresh = SessionHistoryScanner.claudeSessions(root: claudePath)
            fresh.append(contentsOf: SessionHistoryScanner.codexSessions(root: codexPath))
            fresh.append(contentsOf: SessionHistoryScanner.cursorSessions(dbPath: cursorPath))
            fresh.append(contentsOf: SessionHistoryScanner.ingestPending())
            let merged = SessionHistoryStore.upsert(fresh)
            SessionHistoryCache.save(
                records: merged,
                claudePath: claudePath, codexPath: codexPath, cursorPath: cursorPath
            )
            return merged
        }.value

        records = loaded
        let delta = loaded.filter { known[$0.id] != $0 }
        for record in loaded { known[record.id] = record }
        if !delta.isEmpty { onChanged?(delta) }
    }
}
