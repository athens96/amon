import Foundation

/// Devin 런타임 — 원본 openusage `DevinProvider` 의 refresh 로직을 그대로 이식하되,
/// UI 위젯 서술자(WidgetDescriptor)·아이콘 시스템은 제외하고 A-mon 슬림 `Provider` 를 쓴다.
@MainActor
final class DevinProvider: ProviderRuntime {
    let provider = Provider(
        id: "devin",
        displayName: "Devin",
        symbol: "cpu.fill",
        accentHex: Palette.hexDevin,
        links: [
            ProviderLink(label: "Dashboard", url: "https://app.devin.ai/settings/plans")
        ]
    )

    let authStore: DevinAuthStore
    let usageClient: DevinUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: DevinAuthStore = DevinAuthStore(),
        usageClient: DevinUsageClient = DevinUsageClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the credentials file, then the Devin app's stored auth.
        if authStore.loadCredentialsFile() != nil { return true }
        return await loadOffMainActor { [authStore] in authStore.loadAppAuth() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        var sawAPIKey = false
        var sawAuthFailure = false
        let credentials = authStore.loadCredentialsFile()

        if let credentials {
            sawAPIKey = true
            switch await attempt(auth: credentials) {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .unavailable:
                break
            }
        }

        let appAuth = await loadOffMainActor({ [authStore] in authStore.loadAppAuth() })
        if let appAuth,
           credentials == nil || shouldAttemptAppAuth(appAuth, after: credentials) {
            sawAPIKey = true
            switch await attempt(auth: appAuth) {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .unavailable:
                break
            }
        }

        if sawAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
        }
        if sawAPIKey {
            return ProviderSnapshot.error(provider: provider, error: DevinUsageError.quotaUnavailable)
        }
        return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
    }

    private func attempt(auth: DevinAuth) async -> DevinAuthAttempt {
        let apiServerURL = authStore.effectiveAPIServerURL(auth)
        do {
            let response = try await usageClient.fetchUserStatus(auth: auth, apiServerURL: apiServerURL)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .authFailure
            }
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable
            }
            return .success(try DevinUsageMapper.mapUserStatusResponse(response))
        } catch {
            return .unavailable
        }
    }

    private func shouldAttemptAppAuth(_ appAuth: DevinAuth, after credentials: DevinAuth?) -> Bool {
        guard let credentials else { return true }
        return appAuth.apiKey != credentials.apiKey ||
            authStore.effectiveAPIServerURL(appAuth) != authStore.effectiveAPIServerURL(credentials)
    }

    private func snapshot(from mapped: DevinMappedUsage) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }
}

private enum DevinAuthAttempt {
    case success(DevinMappedUsage)
    case authFailure
    case unavailable
}
