import Foundation

/// Cursor 런타임 — 원본 openusage `CursorProvider` 의 refresh 로직을 그대로 이식하되, 스팬드 타일
/// (usage-events CSV export → Today/Yesterday/Last 30 Days/트렌드)과 UI 위젯 서술자(WidgetDescriptor)·
/// 아이콘 시스템은 제외하고 amon 슬림 `Provider` 를 쓴다. 라이브 쿼터(Credits/Total·Auto·API usage/
/// Requests/Extra Usage)만 남긴다.
@MainActor
final class CursorProvider: ProviderRuntime {
    let provider = Provider(
        id: "cursor",
        displayName: "Cursor",
        symbol: "cursorarrow.rays",
        accentHex: Palette.hexCursor,
        links: [
            ProviderLink(label: "Status", url: "https://status.cursor.com/"),
            ProviderLink(label: "Dashboard", url: "https://www.cursor.com/dashboard")
        ]
    )

    let authStore: CursorAuthStore
    let usageClient: CursorUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        usageClient: CursorUsageClient = CursorUsageClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: any auth state (state DB or keychain) counts.
        await loadOffMainActor { [authStore] in authStore.loadAuthState() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let state = await loadOffMainActor({ [authStore] in authStore.loadAuthState() }) else {
            return ProviderSnapshot.error(provider: provider, error: CursorAuthError.notLoggedIn)
        }

        do {
            return try await probe(authState: state)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func probe(authState initialState: CursorAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        var accessToken = authState.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if authStore.needsRefresh(accessToken) {
            do {
                if let refreshed = try await refreshAccessToken(authState: authState) {
                    authState.accessToken = refreshed
                    accessToken = refreshed
                } else if accessToken == nil {
                    throw CursorAuthError.notLoggedIn
                }
            } catch {
                if accessToken == nil {
                    throw error
                }
            }
        }

        guard let accessToken else {
            throw CursorAuthError.notLoggedIn
        }

        let usageResponse = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        try ProviderAuthRetry.requireSuccess(
            usageResponse,
            authExpired: CursorAuthError.tokenExpired,
            requestFailed: { CursorUsageError.requestFailed($0) }
        )
        guard let usage = ProviderParse.jsonObject(usageResponse.body) else {
            throw CursorUsageError.invalidResponse
        }
        // The access token may have rotated during the usage fetch's refresh-and-retry; read the live one.
        let currentToken = authState.accessToken ?? accessToken

        let (planName, planInfoUnavailable) = await fetchPlanName(accessToken: currentToken)
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage,
            planName: planName,
            planInfoUnavailable: planInfoUnavailable
        )
        if fallback.shouldFallback {
            let mapped = try await requestBasedResult(
                accessToken: currentToken,
                planName: planName,
                unavailableMessage: fallback.message
            )
            return snapshot(mapped)
        }

        if shouldTryGenericRequestFallback(usage: usage) {
            if let mapped = try? await requestBasedResult(
                accessToken: currentToken,
                planName: planName,
                unavailableMessage: "Cursor request-based usage data unavailable. Try again later."
            ) {
                return snapshot(mapped)
            }
        }

        let creditGrants = await fetchCreditGrants(accessToken: currentToken)
        let stripeResponse = try? await usageClient.fetchStripeBalance(accessToken: currentToken)
        let stripeBalanceCents = CursorUsageMapper.stripeBalanceCents(from: stripeResponse ?? nil)
        let mapped = try CursorUsageMapper.mapUsage(
            usage: usage,
            planName: planName,
            creditGrants: creditGrants,
            stripeBalanceCents: stripeBalanceCents
        )
        return snapshot(mapped)
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CursorAuthState) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = try await self.refreshAccessToken(authState: working) else {
                    throw CursorAuthError.tokenExpired
                }
                working.accessToken = refreshed
                return refreshed
            },
            connectionFailed: CursorUsageError.connectionFailed,
            retriedConnectionFailed: CursorUsageError.usageAfterRefreshFailed,
            authExpired: CursorAuthError.tokenExpired
        )
    }

    private func refreshAccessToken(authState: CursorAuthState) async throws -> String? {
        guard let refreshToken = authState.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }

        let response = try await usageClient.refreshToken(refreshToken)
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = ProviderParse.jsonObject(response.body)
            if body?["shouldLogout"] as? Bool == true {
                throw CursorAuthError.sessionExpired
            }
            throw CursorAuthError.tokenExpired
        }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body)
        else {
            return nil
        }
        if body["shouldLogout"] as? Bool == true {
            throw CursorAuthError.sessionExpired
        }
        guard let accessToken = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        // Fail loudly, but do NOT interpolate the error: the Cursor token is persisted via a SQL
        // statement that embeds the token, and a sqlite3 failure surfaces as stderr that could echo a
        // fragment of that statement (JWTs aren't covered by log redaction). A generic error line keeps
        // it loud without risking a token leak. The refreshed token still works for this session.
        do {
            try authStore.saveAccessToken(accessToken, source: authState.source)
        } catch {
            AppLog.error(LogTag.auth("cursor"), "failed to persist rotated access token to the Cursor state DB; using it for this session only")
        }
        return accessToken
    }

    private func fetchPlanName(accessToken: String) async -> (String?, Bool) {
        do {
            let response = try await usageClient.fetchPlan(accessToken: accessToken)
            guard (200..<300).contains(response.statusCode),
                  let body = ProviderParse.jsonObject(response.body),
                  let planInfo = body["planInfo"] as? [String: Any]
            else {
                return (nil, true)
            }
            return (planInfo["planName"] as? String, false)
        } catch {
            return (nil, true)
        }
    }

    private func fetchCreditGrants(accessToken: String) async -> [String: Any]? {
        guard let response = try? await usageClient.fetchCredits(accessToken: accessToken),
              (200..<300).contains(response.statusCode)
        else {
            return nil
        }
        return ProviderParse.jsonObject(response.body)
    }

    private func requestBasedResult(accessToken: String, planName: String?, unavailableMessage: String) async throws -> CursorMappedUsage {
        do {
            guard let response = try await usageClient.fetchRequestBasedUsage(accessToken: accessToken),
                  (200..<300).contains(response.statusCode),
                  let body = ProviderParse.jsonObject(response.body)
            else {
                throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
            }
            return try CursorUsageMapper.mapRequestBasedUsage(body, planName: planName, unavailableMessage: unavailableMessage)
        } catch let error as CursorUsageError {
            throw error
        } catch {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }
    }

    private func shouldTryGenericRequestFallback(usage: [String: Any]) -> Bool {
        guard usage["enabled"] as? Bool != false,
              let planUsage = usage["planUsage"] as? [String: Any]
        else {
            return false
        }
        return ProviderParse.number(planUsage["limit"]) == nil
            && ProviderParse.number(planUsage["totalPercentUsed"]) == nil
    }

    private func snapshot(_ mapped: CursorMappedUsage) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }
}
