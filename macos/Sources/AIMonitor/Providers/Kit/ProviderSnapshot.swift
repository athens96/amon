import Foundation

/// 한 프로바이더 refresh 의 정규화 결과. (원본에서 텔레메트리용 errorCategory 는 제외.)
struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    let displayName: String
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
    /// 성공 스냅샷에 실리는 비차단 경고(예: Claude "라이브 사용량 보려면 재로그인"). 헤더에 앰버 삼각형으로 노출.
    var warning: String?

    init(
        providerID: String,
        displayName: String,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        warning: String? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.warning = warning
    }

    func line(label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    /// 에러 스냅샷이면 그 메시지, 아니면 nil. `error(provider:...)` 팩토리는 에러 배지
    /// 한 줄짜리 스냅샷을 만들므로, 그 형태를 그대로 판별한다.
    var errorMessage: String? {
        guard lines.count == 1, let first = lines.first, first.isError,
              case .badge(_, let text, _, _) = first
        else { return nil }
        return text
    }

    static func make(provider: Provider, plan: String?, lines: [MetricLine], refreshedAt: Date, warning: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            warning: warning
        )
    }

    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        Self.error(provider: provider, message: error.localizedDescription)
    }

    static func error(provider: Provider, message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.errorBadgeLabel, text: message, colorHex: "#EF4444")]
        )
    }
}
