import Foundation

/// Copilot 런타임 — 원본 openusage `CopilotProvider` 의 refresh 로직을 그대로 이식하되,
/// UI 위젯 서술자(WidgetDescriptor)·아이콘 시스템은 제외하고 amon 슬림 `Provider` 를 쓴다.
@MainActor
final class CopilotProvider: ProviderRuntime {
    let provider = Provider(
        id: "copilot",
        displayName: "GitHub Copilot",
        symbol: "chevron.left.forwardslash.chevron.right",
        accentHex: Palette.hexCopilot,
        links: [
            ProviderLink(label: "Status", url: "https://www.githubstatus.com/"),
            ProviderLink(label: "Dashboard", url: "https://github.com/settings/billing")
        ]
    )

    let authStore: CopilotAuthStore
    let usageClient: CopilotUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: CopilotAuthStore = CopilotAuthStore(),
        usageClient: CopilotUsageClient = CopilotUsageClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: editor config, gh config, or the gh keychain entry.
        await loadOffMainActor { [authStore] in authStore.loadToken() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        // apps.json 에는 구/신 Copilot 앱 토큰이 공존할 수 있고 일부는 만료 상태다.
        // 후보를 순서대로 시도해 처음으로 인증에 성공한 응답을 쓴다 — 단일 토큰만
        // 읽으면 어떤 항목이 걸리느냐에 따라 401 이 났다 안 났다 한다.
        let candidates = await loadOffMainActor { [authStore] in authStore.loadTokenCandidates() }
        guard !candidates.isEmpty else {
            return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.notLoggedIn)
        }

        do {
            for token in candidates {
                let response = try await usageClient.fetchUsage(token: token.value)

                if response.statusCode == 401 || response.statusCode == 403 {
                    continue  // 만료/폐기된 후보 — 다음 토큰으로.
                }
                guard (200..<300).contains(response.statusCode) else {
                    return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.requestFailed(response.statusCode))
                }

                let mapped = try CopilotUsageMapper.map(response)
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
            }
            // 모든 후보가 401/403 — 재로그인 필요.
            return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.tokenInvalid)
        } catch let error as CopilotUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.connectionFailed)
        }
    }
}
