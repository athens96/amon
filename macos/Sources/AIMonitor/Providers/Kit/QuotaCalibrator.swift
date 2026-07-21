import Foundation

/// 쿼터 %→토큰 수 추론 캘리브레이터 (방법 A — 개인 환율 학습).
///
/// 프로바이더 쿼터 API 는 창 사용률(%)만 주고 토큰 수는 주지 않는다. 하지만 같은 기계에서
/// 로컬 로그(UsageScanner)의 실측 토큰과 쿼터 % 를 동시에 관측하므로, 갱신 구간의
/// Δtokens/Δ% 로 "1% ≈ N tokens" 개인 환율을 학습할 수 있다. 환율이 잡히면:
///   사용 토큰 ≈ 사용% × 환율, 남은 토큰 ≈ 남은% × 환율.
///
/// 표본 규칙 (오염 방지):
/// - Δ% ≥ 1 일 때만 표본 채택 (Codex 정수 % 플로어 대응 — 그 전까지 베이스라인 유지해 토큰 누적)
/// - % 하락 = 창 리셋 → 베이스라인 교체, 표본 없음
/// - Δ% > 0 인데 Δtokens ≤ 0 = 다른 기기/웹 사용 → 표본 버림(환율 오염 방지), 베이스라인 교체
/// - 베이스라인 6시간 초과 = 스테일 → 교체
/// - EWMA(α=0.3) 로 평활 — 모델 믹스 변화를 따라가되 출렁임 억제
///
/// 결과는 항상 추정치(≈)로 표시한다 — 한도가 순수 토큰이 아니라 모델 가중 비용일 수
/// 있고(Opus 가 % 를 더 빨리 깎음), 계정 전체 % vs 이 기계 로그라는 시야 차가 있다.
@MainActor
final class QuotaCalibrator: ObservableObject {

    /// 캘리브레이션 대상 — 로컬 로그가 있는 프로바이더 ↔ UsageScanner 도구 매핑.
    static let providerToTool: [String: AITool] = [
        "claude": .claudeCode,
        "codex": .codex,
    ]
    /// 환율을 학습할 % 미터 라벨 (모델 스코프 라벨(Sonnet/Fable/Spark)은 로컬 총토큰과
    /// 분모가 달라 제외).
    static let calibratableLabels: Set<String> = ["Session", "Weekly"]

    /// 표본 채택 최소 Δ% — 정수 % 미터(Codex)에서 신호가 잡히는 최소 단위.
    private static let minDeltaPercent = 1.0
    /// 이보다 % 가 내려가면 창 리셋으로 본다.
    private static let resetDropThreshold = -0.5
    /// 베이스라인 최대 나이 — 넘으면 스테일로 교체.
    private static let staleBaseline: TimeInterval = 6 * 60 * 60
    private static let ewmaAlpha = 0.3
    private static let defaultsKey = "quota.calibration.v1"

    /// 학습된 환율 (tokens per 1%). 키 = "providerID|label".
    struct Rate: Codable, Equatable {
        var tokensPerPercent: Double
        var samples: Int
    }

    private struct Baseline {
        var percent: Double
        var tokens: Int
        var at: Date
    }

    @Published private(set) var rates: [String: Rate] = [:]
    private var baselines: [String: Baseline] = [:]
    /// false 면 UserDefaults 를 건드리지 않는다 (검증/테스트용).
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        if persist { load() }
    }

    private static func key(_ providerID: String, _ label: String) -> String {
        "\(providerID)|\(label)"
    }

    /// 한 쿼터 갱신 시점의 (사용%, 로컬 누적토큰) 페어를 기록한다.
    /// `cumulativeTokens` 는 매핑된 도구의 로그 전체 누적(단조 증가) — UsageScanner 결과.
    func record(providerID: String, label: String, usedPercent: Double, cumulativeTokens: Int, now: Date = Date()) {
        guard Self.providerToTool[providerID] != nil,
              Self.calibratableLabels.contains(label),
              usedPercent.isFinite, usedPercent >= 0
        else { return }
        let key = Self.key(providerID, label)

        guard let base = baselines[key] else {
            baselines[key] = Baseline(percent: usedPercent, tokens: cumulativeTokens, at: now)
            return
        }

        let deltaPercent = usedPercent - base.percent
        let deltaTokens = cumulativeTokens - base.tokens

        // 창 리셋(% 하락) 또는 스테일 베이스라인 → 표본 없이 교체.
        if deltaPercent < Self.resetDropThreshold || now.timeIntervalSince(base.at) > Self.staleBaseline {
            baselines[key] = Baseline(percent: usedPercent, tokens: cumulativeTokens, at: now)
            return
        }
        // 신호가 아직 약함(Δ% < 1) → 베이스라인 유지해 토큰을 계속 누적.
        guard deltaPercent >= Self.minDeltaPercent else { return }

        // % 는 올랐는데 이 기계 토큰이 안 늘었다 = 다른 기기/웹 사용 → 표본 버림.
        guard deltaTokens > 0 else {
            baselines[key] = Baseline(percent: usedPercent, tokens: cumulativeTokens, at: now)
            return
        }

        let sample = Double(deltaTokens) / deltaPercent
        if var rate = rates[key] {
            rate.tokensPerPercent =
                rate.tokensPerPercent * (1 - Self.ewmaAlpha) + sample * Self.ewmaAlpha
            rate.samples += 1
            rates[key] = rate
        } else {
            rates[key] = Rate(tokensPerPercent: sample, samples: 1)
        }
        baselines[key] = Baseline(percent: usedPercent, tokens: cumulativeTokens, at: now)
        save()
    }

    /// 추정 결과 — 환율이 아직 없으면 nil.
    struct Estimate {
        let usedTokens: Double
        let remainingTokens: Double
        let samples: Int
    }

    func estimate(providerID: String, label: String, usedPercent: Double) -> Estimate? {
        guard let rate = rates[Self.key(providerID, label)], rate.tokensPerPercent > 0 else { return nil }
        return Estimate(
            usedTokens: usedPercent * rate.tokensPerPercent,
            remainingTokens: max(0, 100 - usedPercent) * rate.tokensPerPercent,
            samples: rate.samples
        )
    }

    /// 미터 아래 병기할 추정 문구 — "≈ 6.0M 사용 · ≈ 18M 남음 (추정)".
    func estimateText(providerID: String, label: String, usedPercent: Double) -> String? {
        guard let est = estimate(providerID: providerID, label: label, usedPercent: usedPercent) else {
            return nil
        }
        let used = TokenFormat.compact(Int(est.usedTokens.rounded()))
        let left = TokenFormat.compact(Int(est.remainingTokens.rounded()))
        return "≈ \(used) 사용 · ≈ \(left) 남음 (추정)"
    }

    /// 추정 문구의 설명 툴팁.
    func estimateHelp(providerID: String, label: String) -> String {
        let samples = rates[Self.key(providerID, label)]?.samples ?? 0
        return "로컬 로그 Δ토큰 ÷ 쿼터 Δ% 로 학습한 개인 환율 추정 (표본 \(samples)회). "
            + "다른 기기/웹 사용, 모델별 가중치에 따라 오차가 있습니다."
    }

    // MARK: - 영속화 (UserDefaults JSON — 환율만; 베이스라인은 런타임 전용)

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Rate].self, from: data)
        else { return }
        rates = decoded
    }

    private func save() {
        guard persist, let data = try? JSONEncoder().encode(rates) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
