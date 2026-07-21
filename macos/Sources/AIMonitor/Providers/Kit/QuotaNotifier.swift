import Foundation
import UserNotifications

/// 쿼터 한도 임박 macOS 알림 — openusage 의 "잔여 10% 미만" 규칙 이식.
///
/// 쿼터 갱신마다 모든 bounded 미터(progress 라인)의 잔여 비율을 검사해, 10% 미만으로
/// 떨어지는 순간 한 번 알림을 보낸다. 같은 소진 에피소드에서 반복 발사하지 않도록
/// 발사 키를 기억하고, 잔여가 15% 이상으로 회복(창 리셋)되면 재장전한다(히스테리시스).
///
/// 헤드리스 실행(--providers 등, .app 번들 밖) 에서는 UNUserNotificationCenter 가
/// 크래시하므로 번들 ID 가 없으면 조용히 건너뛴다.
@MainActor
final class QuotaNotifier {
    /// 알림 발사 기준 — 잔여 비율이 이 이하로 떨어지면 발사 (openusage 10% 규칙).
    static let remainingThreshold = 0.10
    /// 재장전 기준 — 잔여가 이 이상으로 회복되면(창 리셋) 다시 알릴 수 있다.
    static let rearmThreshold = 0.15

    /// 이번 소진 에피소드에서 이미 알린 미터 키("providerID|label").
    private var fired: Set<String> = []
    private var authorizationRequested = false

    /// 갱신된 스냅샷들의 bounded 미터를 검사해 한도 임박 알림을 보낸다.
    func check(_ snapshots: [ProviderSnapshot]) {
        // .app 번들 밖(헤드리스 CLI)에서는 알림 API 자체가 크래시 — 조용히 스킵.
        guard Bundle.main.bundleIdentifier != nil else { return }

        for snapshot in snapshots {
            for line in snapshot.lines {
                guard case .progress(let label, let used, let limit, let format, let resetsAt, _, _) = line,
                      limit > 0
                else { continue }
                let remaining = max(0, min((limit - used) / limit, 1))
                let key = "\(snapshot.providerID)|\(label)"

                if remaining <= Self.remainingThreshold {
                    guard !fired.contains(key) else { continue }
                    fired.insert(key)
                    send(provider: snapshot.displayName, label: label,
                         used: used, limit: limit, format: format, resetsAt: resetsAt)
                } else if remaining >= Self.rearmThreshold {
                    fired.remove(key)  // 창 리셋/회복 — 다음 소진 때 다시 알림
                }
            }
        }
    }

    private func send(
        provider: String, label: String,
        used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?
    ) {
        var body = "\(MetricFormat.progressTrailing(used: used, limit: limit, format: format)) 사용"
        if let resetsAt, let cd = MeterEngine.compactDuration(resetsAt.timeIntervalSinceNow) {
            body += " — 리셋까지 \(cd)"
        }
        let content = UNMutableNotificationContent()
        content.title = "\(provider) \(label) 한도 임박"
        content.body = body
        content.sound = .default

        Task {
            let center = UNUserNotificationCenter.current()
            if !authorizationRequested {
                authorizationRequested = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            // 권한이 거부돼 있으면 add 가 조용히 실패한다 — 그걸로 충분.
            try? await center.add(
                UNNotificationRequest(
                    identifier: "quota.\(provider).\(label)",
                    content: content,
                    trigger: nil
                )
            )
            AppLog.info(.config, "quota alert sent: \(provider) \(label)")
        }
    }
}
