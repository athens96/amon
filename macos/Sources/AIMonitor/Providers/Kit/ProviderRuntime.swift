import Foundation

/// amon 이 추적할 수 있는 한 AI 프로바이더. 기기의 기존 자격증명을 읽고 → API 를 호출하고 →
/// `ProviderSnapshot`(라이브 쿼터 MetricLine) 으로 정규화한다. (원본 openusage 계약의 슬림 버전.)
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }

    /// 최신 스냅샷. 실패 시 `ProviderSnapshot.error(...)` 반환.
    func refresh() async -> ProviderSnapshot

    /// 이 기기에 자격증명이 존재하는지 — 값싼 로컬 전용 검사(파일/keychain, 네트워크 X).
    /// 첫 실행 시 실제 보유한 프로바이더만 켜는 데 쓴다. 블로킹 로드는 `loadOffMainActor` 로.
    func hasLocalCredentials() async -> Bool
}

/// 블로킹(`security`/`sqlite3` CLI 대기 등) `Sendable` 자격증명 로드를 MainActor 밖에서 돌린다.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility, operation: load).value
}
