import Foundation

/// OpenRouter 런타임 — 원본 openusage `OpenRouterProvider` 의 refresh 로직을 그대로 이식하되,
/// UI 위젯 서술자(WidgetDescriptor)·아이콘 시스템은 제외하고 A-mon 슬림 `Provider` 를 쓴다.
@MainActor
final class OpenRouterProvider: ProviderRuntime {
    let provider = Provider(
        id: "openrouter",
        displayName: "OpenRouter",
        symbol: "arrow.triangle.branch",
        accentHex: "#6467f2",
        links: [
            ProviderLink(label: "Activity", url: "https://openrouter.ai/activity"),
            ProviderLink(label: "Credits", url: "https://openrouter.ai/settings/credits")
        ]
    )

    let authStore: OpenRouterAuthStore
    let usageClient: OpenRouterUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OpenRouterAuthStore = OpenRouterAuthStore(),
        usageClient: OpenRouterUsageClient = OpenRouterUsageClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: OpenRouterAuthError.missingKey)
        }

        // 두 엔드포인트는 독립적으로 조회해 성공한 쪽만 매핑한다 — `/credits` 는 잔액,
        // `/key` 는 티어+기간 지출. OpenRouter 는 키 종류에 따라 일부 엔드포인트를 막으므로
        // 한쪽 403 이 다른 쪽의 데이터를 지워선 안 된다.
        let credits = await load { try await usageClient.fetchCredits(apiKey: auth.apiKey) }
        let key = await load { try await usageClient.fetchKey(apiKey: auth.apiKey) }

        var lines: [MetricLine] = []
        var plan: String?
        if case .success(let data) = credits {
            lines += OpenRouterUsageMapper.creditsLines(from: data)
        }
        if case .success(let data) = key {
            let mapped = OpenRouterUsageMapper.keyMetrics(from: data)
            plan = mapped.plan
            lines += mapped.lines
        }

        if !lines.isEmpty {
            return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines, refreshedAt: now())
        }

        // 키 무효 판정은 두 엔드포인트가 모두 401/403 을 반환했을 때만 — 한쪽만 거부됐다면
        // (예: `/credits` 만 403) 키는 유효하되 게이팅된 것이지 무효가 아니다.
        if credits.isAuthFailure && key.isAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: OpenRouterAuthError.invalidKey)
        }
        let error = credits.failureError ?? key.failureError ?? OpenRouterUsageError.invalidResponse
        return ProviderSnapshot.error(provider: provider, error: error)
    }

    private func load(_ call: () async throws -> HTTPResponse) async -> EndpointResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            guard let data = OpenRouterUsageMapper.dataObject(response.body) else {
                return .failed(.invalidResponse)
            }
            return .success(data)
        } catch {
            return .failed(.connectionFailed)
        }
    }
}

private enum EndpointResult {
    case success([String: Any])
    case authFailure
    case failed(OpenRouterUsageError)

    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }
    var failureError: OpenRouterUsageError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
