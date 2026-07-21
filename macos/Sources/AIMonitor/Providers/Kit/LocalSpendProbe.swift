import Foundation

/// 로컬 정보(로그 스캔) 기반 스팬드 타일(오늘/어제/최근 30일) 수집 루틴.
///
/// openusage 는 Claude/Codex/Grok 의 로컬 세션 로그를 스캔해 일자별 토큰·추정 비용을
/// Today / Yesterday / Last 30 Days 타일로 프로바이더 카드에 함께 표시한다
/// (Claude: ~/.claude/projects, Codex: ~/.codex/sessions, Grok: ~/.grok/logs/unified.jsonl).
///
/// A-mon 은 이 수집을 이미 `UsageScanner`(토큰 소비 보고 경로)가 하고 있으므로,
/// 여기서는 **얻어오는 루틴(진입점)만** 둔다 — 지금은 빈 결과를 반환해 화면에는
/// 프로바이더 API 로 얻은 라이브 데이터만 표시된다. 나중에 스팬드 타일을 켤 때
/// `UsageScanner.scanAll` 의 일자 버킷을 (토큰 → MetricLine.values) 로 변환해
/// 여기서 반환하면 카드에 그대로 합류한다.
struct LocalSpendProbe: Sendable {

    /// providerID → 로컬 로그 위치(참고용, openusage 와 동일한 소스).
    /// 라우팅 테이블 자체가 "무엇을 로컬에서 얻는가" 의 명세다.
    static let localSources: [String: String] = [
        "claude": "~/.claude/projects (세션 .jsonl)",
        "codex": "~/.codex/sessions · archived_sessions (rollout .jsonl)",
        "grok": "~/.grok/logs/unified.jsonl",
    ]

    /// 이 프로바이더가 로컬 스팬드 수집 대상인지.
    static func supportsLocalSpend(_ providerID: String) -> Bool {
        localSources[providerID] != nil
    }

    /// 한 프로바이더의 로컬 스팬드 라인(오늘/어제/최근 30일)을 수집한다.
    ///
    /// 지금은 루틴만 — 빈 배열을 반환한다(표시 데이터는 라이브 프로바이더 전용).
    /// TODO: UsageScanner 일자 버킷 연동 시 아래 형태로 반환:
    ///   .values(label: "오늘", values: [MetricValue(number: tokens, kind: .count, label: "tokens")])
    ///   .values(label: "어제", …), .values(label: "최근 30일", …)
    func fetchSpendLines(providerID: String) async -> [MetricLine] {
        guard Self.supportsLocalSpend(providerID) else { return [] }
        // 로컬 로그 스캔 진입점 — 현재는 수집을 수행하지 않는다.
        return []
    }
}
