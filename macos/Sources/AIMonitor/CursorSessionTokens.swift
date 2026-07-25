import Foundation

/// Cursor 세션별 토큰 **추정** — 로컬 DB 에는 세션당 토큰이 없어(버블 tokenCount
/// 전부 0, v3.x 실측) 대시보드 CSV 사용-이벤트를 세션(composer)에 시간 귀속시켜
/// 추정한다. 추정치라 실제 청구 소비와 어긋날 수 있다 — 특히 같은 계정을 다른
/// 기기에서도 쓰는 경우 그 소비가 이 기기 세션에 끼어들 수 있다.
///
/// 귀속 규칙: 이벤트 시각에서 **가장 가까운 버블**을 가진 composer 가 임자.
/// composer 의 [createdAt, lastUpdatedAt] 창은 유휴를 끼고 며칠씩 벌어질 수 있어
/// (실측 28h) 창 포함 여부가 아니라 버블 거리로 판정하고, 최근접 거리가
/// `maxGap` 을 넘는 이벤트는 어떤 세션에도 귀속하지 않는다.
///
/// 이벤트 캐시는 디스크(`cache/cursor-events.json`)에 영속한다 — 앱 재시작 직후
/// 네트워크가 없어도 직전 이벤트로 추정을 유지해, 로컬 기록 값이 0으로
/// 출렁였다 복구되는 왕복을 막는다(쿼터 축과 같은 stale-while-revalidate 원칙).
enum CursorSessionTokens {

    /// 이벤트 ↔ 최근접 버블 허용 최대 간격. 어시스턴트 버블은 생성 중에도 계속
    /// 쌓여 정상 세션에선 간격이 작다 — 이보다 멀면 남의(다른 기기) 소비로 본다.
    static let maxGap: TimeInterval = 10 * 60
    /// CSV 재조회 최소 간격 — 세션 기록 스캔(60초)마다 네트워크를 치지 않는다.
    static let refreshTTL: TimeInterval = 5 * 60

    // MARK: - 이벤트 캐시 (메모리 + 디스크)

    struct CacheFile: Codable {
        let fetchedAt: Date
        let events: [CursorUsageEvents.RawEvent]
    }

    private static let lock = NSLock()
    private static var memo: CacheFile?
    private static var diskLoaded = false
    /// 테스트에서 임시 경로로 바꿀 수 있게 var.
    static var fileURL = AmonPaths.cache.appendingPathComponent("cursor-events.json")

    static func events() -> [CursorUsageEvents.RawEvent] {
        load()?.events ?? []
    }

    private static func load() -> CacheFile? {
        lock.lock()
        defer { lock.unlock() }
        if memo == nil, !diskLoaded {
            diskLoaded = true
            if let data = try? Data(contentsOf: fileURL) {
                memo = try? AmonJSON.decoder().decode(CacheFile.self, from: data)
            }
        }
        return memo
    }

    /// 새로 받은 이벤트를 캐시에 반영한다. 사용량 스캔(10분)과 세션 스캔(60초)
    /// 어느 쪽이 받아 왔든 같은 캐시를 쓴다.
    static func store(events: [CursorUsageEvents.RawEvent]) {
        let entry = CacheFile(fetchedAt: Date(), events: events)
        lock.lock()
        memo = entry
        diskLoaded = true
        lock.unlock()
        guard let data = try? AmonJSON.encoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// TTL 이 지났을 때만 CSV 를 다시 받는다. 실패(오프라인·자격증명 없음)하면
    /// 기존 캐시를 그대로 유지한다.
    static func refreshIfStale() async {
        if let cached = load(), Date().timeIntervalSince(cached.fetchedAt) < refreshTTL { return }
        guard let result = await CursorUsageEvents.fetchDaily() else { return }
        store(events: result.rawEvents)
    }

    // MARK: - 귀속(추정)

    struct Estimate {
        var usage = TokenUsage()
        /// 모델별 total 합 — CSV 의 Model 컬럼이라 composer 의 "auto" 보다 구체적이다.
        var models: [String: Int] = [:]
    }

    /// 각 이벤트를 최근접 버블 세션에 귀속한다. 순수 함수 — 테스트 대상.
    static func attribute(
        events: [CursorUsageEvents.RawEvent],
        sessions: [(id: String, bubbles: [Date])]
    ) -> [String: Estimate] {
        let candidates = sessions
            .map { (id: $0.id, bubbles: $0.bubbles.map(\.timeIntervalSince1970).sorted()) }
            .filter { !$0.bubbles.isEmpty }
        guard !candidates.isEmpty, !events.isEmpty else { return [:] }

        var out: [String: Estimate] = [:]
        for event in events {
            let t = event.date.timeIntervalSince1970
            var bestID: String?
            var bestDistance = TimeInterval.greatestFiniteMagnitude
            for candidate in candidates {
                let distance = nearestDistance(t, in: candidate.bubbles)
                if distance < bestDistance {
                    bestDistance = distance
                    bestID = candidate.id
                }
            }
            guard let bestID, bestDistance <= maxGap else { continue }
            var estimate = out[bestID] ?? Estimate()
            estimate.usage = estimate.usage + event.usage
            if !event.model.isEmpty {
                estimate.models[event.model, default: 0] += event.usage.total
            }
            out[bestID] = estimate
        }
        return out
    }

    /// 정렬된 버블 시각 배열에서 t 와 가장 가까운 원소까지의 거리(이진 탐색).
    private static func nearestDistance(
        _ t: TimeInterval, in sortedBubbles: [TimeInterval]
    ) -> TimeInterval {
        var lo = 0
        var hi = sortedBubbles.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedBubbles[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var best = TimeInterval.greatestFiniteMagnitude
        if lo < sortedBubbles.count { best = min(best, abs(sortedBubbles[lo] - t)) }
        if lo > 0 { best = min(best, abs(sortedBubbles[lo - 1] - t)) }
        return best
    }
}
