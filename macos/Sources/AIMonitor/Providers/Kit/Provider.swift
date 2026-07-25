import Foundation

/// 추적 대상 AI 프로바이더 메타데이터. (원본 `Provider` 를 슬림화 — 아이콘은 SF Symbol 이름 +
/// 액센트 hex 로 단순화해 별도 아이콘 리소스 이식을 피한다.)
struct Provider: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// SF Symbol 이름 (팝오버 리스트 아이콘).
    let symbol: String
    /// 액센트 색 hex 문자열 (예: Palette.hexClaude). 토큰 출처: Palette
    let accentHex: String
    /// 프로바이더별 퀵링크(상태/콘솔). 지금 UI 에선 선택적.
    let links: [ProviderLink]

    init(id: String, displayName: String, symbol: String = "cpu", accentHex: String = Palette.accentHex, links: [ProviderLink] = []) {
        self.id = id
        self.displayName = displayName
        self.symbol = symbol
        self.accentHex = accentHex
        self.links = links
    }
}

struct ProviderLink: Hashable, Sendable {
    let label: String
    let url: String
}
