import Foundation

/// 한 progress 미터의 시각 상태 — openusage `WidgetData.meterState` 이식.
/// 막대 색·경고 카피·pace 틱이 전부 여기서 한 번 파생되므로 서로 어긋날 수 없다.
///
/// 우선순위(높은 것 먼저): 소진 → 시작 전(신선한 세션 창) → 라이브 pace 판정 → 절대 레벨 밴드.
enum MeterState: Hashable {
    /// 남은 양이 표시 정밀도에서 0 으로 반올림 — 빨강 + "한도 소진".
    case spent
    /// 리셋 전에 한도를 넘길 것으로 투영 — 빨강 + 소진 예상 시각(계산 불가면 nil).
    /// `projectedFraction` = 리셋 시점 투영 사용량 ÷ 한도 (툴팁용).
    case runningOut(eta: String?, projectedFraction: Double)
    /// 마지막 10% 안에 들어올 것으로 투영(여유 ≥1%) — 주황 + "여유 ~N%".
    case closeToLimit(spare: String, projectedFraction: Double)
    /// 여유 ≥10% 로 투영 — 평온(액센트 색).
    case healthy(projectedFraction: Double)
    /// pace 신호 없음(리셋 창 없음/불신) — 사용률 절대 밴드 색만.
    case level(Severity)

    enum Severity: Hashable { case normal, warning, critical }

    var severity: Severity {
        switch self {
        case .spent, .runningOut: return .critical
        case .closeToLimit: return .warning
        case .healthy: return .normal
        case .level(let s): return s
        }
    }

    /// 상태에 딸린 짧은 카피(막대 아래 줄) — 없으면 nil.
    var statusText: String? {
        switch self {
        case .spent: return "한도 소진"
        case .runningOut(let eta, _): return eta.map { "소진까지 \($0)" } ?? "한도 초과 페이스"
        case .closeToLimit(let spare, _): return spare
        case .healthy, .level: return nil
        }
    }

    /// 호버 툴팁 — 리셋 시점 투영치 한 줄 (openusage `MeterState.tooltip` 이식).
    var tooltip: String? {
        switch self {
        case .level: return nil
        case .spent: return "한도 소진"
        case .healthy(let p):
            return "리셋 시점 ~\(Int(((1 - p) * 100).rounded()))% 남음 예상"
        case .closeToLimit(_, let p):
            return "리셋 시점 ~\(Int((p * 100).rounded()))% 사용 예상"
        case .runningOut(_, let p):
            guard p > 1 else { return "리셋 시점 ~100% 사용 예상" }
            return "리셋 시점 한도 ~\(max(1, Int(((p - 1) * 100).rounded())))% 초과 예상"
        }
    }
}

/// MetricLine.progress 필드에서 미터 상태·pace 틱·트레일링 문구를 파생한다.
/// (openusage 는 WidgetData 를 경유하지만, amon 은 MetricLine 을 직접 렌더하므로 여기서 계산.)
enum MeterEngine {
    /// 세션(롤링 서브데일리) 창으로 볼 최대 주기 — 5h 세션 + 여유. 주간/월간 창은 해당 없음.
    private static let sessionWindowMaxMs = 6 * 60 * 60 * 1000

    /// 신선한 세션 창("시작 전") — openusage `isFreshSessionWindow` 이식.
    /// 사용량 0 + 리셋 미도래 + 서브데일리 롤링 창일 때만. (used==0 이 스냅샷과 함께 안정된 신호)
    static func isFreshSessionWindow(
        used: Double, resetsAt: Date?, periodDurationMs: Int?, now: Date = Date()
    ) -> Bool {
        guard used <= 0, let resetsAt, now < resetsAt,
              let periodMs = periodDurationMs, periodMs > 0, periodMs <= sessionWindowMaxMs
        else { return false }
        return true
    }

    /// "시작 전" 라벨의 설명 툴팁.
    static let freshSessionTooltip = "첫 메시지를 보내면 세션이 시작됩니다."

    /// 미터 상태 — openusage `meterState(now:)` 의 우선순위·불신 규칙 그대로.
    static func state(
        used: Double, limit: Double, format: ProgressFormat,
        resetsAt: Date?, periodDurationMs: Int?, now: Date = Date()
    ) -> MeterState {
        guard limit > 0 else { return .level(.normal) }
        // 1) 소진: 남은 양이 표시 정밀도에서 0 으로 반올림되면 항상 빨강.
        if roundedAtDisplayPrecision(limit - used, format: format) <= 0 { return .spent }
        // 2) 시작 전: pace 를 걸 것이 없다 — 절대 밴드의 평온한 막대.
        if isFreshSessionWindow(used: used, resetsAt: resetsAt, periodDurationMs: periodDurationMs, now: now) {
            return levelState(used: used, limit: limit)
        }
        // 3) 라이브 pace 판정 (한도 + 리셋 창이 있을 때).
        if let resetsAt, let periodMs = periodDurationMs, periodMs > 0 {
            let period = TimeInterval(periodMs) / 1000
            if let result = Pace.evaluate(used: used, limit: limit, resetsAt: resetsAt,
                                          periodDuration: period, now: now) {
                switch result.status {
                case .ahead:
                    return .healthy(projectedFraction: result.projectedUsage / limit)
                case .onTrack:
                    let projected = result.projectedUsage / limit
                    let spare = Int(((1 - projected) * 100).rounded())
                    // 여유가 0% 로 반올림되면 주황이 아니라 빨강으로 승격 (openusage 동일).
                    guard spare >= 1 else { return .runningOut(eta: nil, projectedFraction: projected) }
                    return .closeToLimit(spare: "여유 ~\(spare)%", projectedFraction: projected)
                case .behind:
                    // 거친 정수 퍼센트 미터가 신선한 창에서 1% 로 읽히면 선형 외삽이 가짜 폭주를
                    // 투영한다 — 5% 미만 사용이면 투영을 불신하고 절대 밴드로 (openusage 동일).
                    guard used / limit >= 0.05 else { return levelState(used: used, limit: limit) }
                    let eta = Pace.secondsToRunOut(used: used, limit: limit, resetsAt: resetsAt,
                                                   periodDuration: period, now: now)
                        .flatMap { compactDuration($0) }
                    return .runningOut(eta: eta, projectedFraction: result.projectedUsage / limit)
                }
            }
        }
        // 4) 절대 레벨 밴드.
        return levelState(used: used, limit: limit)
    }

    /// pace 틱 위치(0...1) — 리셋 창의 경과 비율. 주황/빨강 상태에서만 표시 (openusage 기본).
    static func paceTick(
        state: MeterState, resetsAt: Date?, periodDurationMs: Int?, now: Date = Date()
    ) -> Double? {
        switch state {
        case .closeToLimit, .runningOut: break
        case .spent, .healthy, .level: return nil
        }
        guard let resetsAt, let periodMs = periodDurationMs, periodMs > 0 else { return nil }
        let period = TimeInterval(periodMs) / 1000
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
        guard elapsed >= Pace.minimumElapsed(periodDuration: period), now < resetsAt else { return nil }
        return min(max(elapsed / period, 0), 1)
    }

    /// 트레일링 리셋 문구 — "시작 전" / "곧 리셋" / "리셋까지 2h 5m" / 주기 캐던스.
    static func trailingResetText(
        used: Double, resetsAt: Date?, periodDurationMs: Int?, now: Date = Date()
    ) -> String? {
        if isFreshSessionWindow(used: used, resetsAt: resetsAt, periodDurationMs: periodDurationMs, now: now) {
            return "시작 전"
        }
        if let resetsAt {
            let seconds = resetsAt.timeIntervalSince(now)
            if seconds <= 5 * 60 { return "곧 리셋" }  // openusage "soon" 규칙
            return compactDuration(seconds).map { "리셋까지 \($0)" }
        }
        // 정확한 리셋 시각이 없으면 주기 캐던스라도 (openusage boundedSubtitle 폴백).
        if let periodMs = periodDurationMs,
           let duration = compactDuration(TimeInterval(periodMs) / 1000) {
            return "\(duration) 주기 리셋"
        }
        return nil
    }

    /// openusage `Formatters.compactDuration` 이식 — "2d 6h" / "3h 45m" / "12m".
    static func compactDuration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// 헤드라인 표시 정밀도로 반올림 — % 는 정수, $ 는 센트, count 는 소수 1자리.
    /// (미터 지오메트리와 인쇄된 숫자가 어긋나지 않게 — openusage 동일.)
    private static func roundedAtDisplayPrecision(_ value: Double, format: ProgressFormat) -> Double {
        switch format {
        case .percent: return value.rounded()
        case .dollars: return (value * 100).rounded() / 100
        case .count: return (value * 10).rounded() / 10
        }
    }

    private static func levelState(used: Double, limit: Double) -> MeterState {
        let percentUsed = (min(max(used / limit, 0), 1) * 100).rounded()
        if percentUsed >= 90 { return .level(.critical) }
        if percentUsed >= 80 { return .level(.warning) }
        return .level(.normal)
    }
}
