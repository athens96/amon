namespace AMon.Quotas.Providers.Antigravity;

/// Tracks pool quota for Antigravity (Google's Codeium/Windsurf-derived AI IDE). Quotas are
/// fraction-based and shown as up to four percent meters: the shared Gemini pool and the shared
/// non-Gemini pool (Claude, GPT-OSS), each with a rolling 5-hour and a weekly window.
///
/// Probe order, best source first:
/// 1. Antigravity language server (running app) — richest, gives the authoritative plan.
/// 2. `agy` language server (running CLI).
/// 3. Credential Manager token → Google Cloud Code (works with the app closed); refreshes via Google
///    OAuth.
///
/// On each source, `RetrieveUserQuotaSummary` is tried first (the only endpoint reporting the merged
/// pools and the weekly windows); builds without it fall back to the legacy per-model endpoints,
/// which are 5h-only — the weekly meters read "No data" there.
public sealed class AntigravityQuotaProvider(
    AntigravityAuthStore authStore,
    AntigravityUsageClient usageClient,
    LanguageServerDiscovery discovery,
    IQuotaClock clock) : IQuotaProvider
{
    public const string NotSignedInMessage = "Antigravity 를 실행하거나 agy 로 로그인한 뒤 다시 시도해 주세요.";
    public const string AuthExpiredMessage = "Antigravity 로그인이 만료되었습니다. Antigravity 를 열거나 agy 를 실행해 갱신해 주세요.";
    public const string UnavailableMessage = "Antigravity 사용량을 일시적으로 가져올 수 없습니다.";

    public string Id => "antigravity";

    public string DisplayName => "Antigravity";

    /// The stored token (or our refreshed-token cache) is the works-with-the-app-closed source
    /// `RefreshAsync` falls back to; a logged-in Antigravity install has it even when no language
    /// server is running, so process discovery isn't needed here.
    public Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken) =>
        Task.FromResult(authStore.LoadCredentialToken() is not null || authStore.LoadCachedToken() is not null);

    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        try
        {
            var probe = await ProbeAsync(cancellationToken);
            return probe.Result is { } result
                ? QuotaSnapshot.Success(this, result.Plan, result.Lines, clock.Now)
                : QuotaSnapshot.Failure(this, MessageFor(probe.Failure), clock.Now);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            // `RefreshAsync` never throws: an unexpected local failure reads as a transient outage.
            return QuotaSnapshot.Failure(this, UnavailableMessage, clock.Now);
        }
    }

    private enum Failure
    {
        NotSignedIn,
        AuthExpired,
        Unavailable,
    }

    private static string MessageFor(Failure failure) => failure switch
    {
        Failure.NotSignedIn => NotSignedInMessage,
        Failure.AuthExpired => AuthExpiredMessage,
        _ => UnavailableMessage,
    };

    private sealed record StrategyResult(string? Plan, IReadOnlyList<QuotaMetricLine> Lines);

    private sealed record ProbeOutcome(StrategyResult? Result, Failure Failure = Failure.Unavailable);

    private async Task<ProbeOutcome> ProbeAsync(CancellationToken cancellationToken)
    {
        var antigravity = await ProbeLanguageServerAsync(
            new LanguageServerOptions("language_server", ["antigravity", "antigravity-ide"], "--csrf_token", "--extension_server_port"),
            cancellationToken);
        if (antigravity is not null)
            return new ProbeOutcome(antigravity);

        var agy = await ProbeLanguageServerAsync(new LanguageServerOptions("agy", [], string.Empty, null), cancellationToken);
        if (agy is not null)
            return new ProbeOutcome(agy);

        return await ProbeCloudCodeAsync(cancellationToken);
    }

    // MARK: - Language server

    private async Task<StrategyResult?> ProbeLanguageServerAsync(LanguageServerOptions options, CancellationToken cancellationToken)
    {
        if (await discovery.DiscoverAsync(options, cancellationToken) is not { } discovered)
            return null;

        // HTTPS first (the LS serves a self-signed cert), then HTTP, then the HTTP-only extension port.
        var endpoints = new List<(string Scheme, int Port)>();
        foreach (var port in discovered.Ports)
        {
            endpoints.Add(("https", port));
            endpoints.Add(("http", port));
        }
        if (discovered.ExtensionPort is { } extensionPort)
            endpoints.Add(("http", extensionPort));

        foreach (var (scheme, port) in endpoints)
        {
            // The quota summary is authoritative (merged pools + weekly windows), so it goes first.
            // A parsed summary — even one with zero usable buckets — ends the probe: the legacy
            // endpoints below fabricate "fully used" from missing quota info, so an authoritative
            // answer must never fall through to them. Empty lines render as "No data" rows.
            var summary = await usageClient.CallLSAsync(scheme, port, discovered.Csrf, "RetrieveUserQuotaSummary", cancellationToken);
            if (summary is { IsSuccess: true } && AntigravityUsageMapper.ParseQuotaSummary(summary.Body) is { } summaryLines)
            {
                // The plan comes from an independent GetUserStatus call; the summary never gates on
                // it — a failed plan lookup just leaves the plan blank.
                var planStatus = await usageClient.CallLSAsync(scheme, port, discovered.Csrf, "GetUserStatus", cancellationToken);
                var plan = planStatus is { IsSuccess: true }
                    ? AntigravityUsageMapper.ParseUserStatus(planStatus.Body)?.Plan
                    : null;
                return new StrategyResult(plan, summaryLines);
            }

            var status = await usageClient.CallLSAsync(scheme, port, discovered.Csrf, "GetUserStatus", cancellationToken);
            if (status is not { IsSuccess: true })
                continue;

            if (AntigravityUsageMapper.ParseUserStatus(status.Body) is { } parsed)
            {
                var lines = AntigravityUsageMapper.BuildLines(parsed.Configs);
                if (lines.Count > 0)
                    return new StrategyResult(parsed.Plan, lines);
            }

            // The endpoint answered but GetUserStatus had nothing usable — try the documented fallback.
            var fallback = await usageClient.CallLSAsync(scheme, port, discovered.Csrf, "GetCommandModelConfigs", cancellationToken);
            if (fallback is { IsSuccess: true }
                && AntigravityUsageMapper.ParseCommandModelConfigs(fallback.Body) is { } configs)
            {
                var lines = AntigravityUsageMapper.BuildLines(configs);
                if (lines.Count > 0)
                    return new StrategyResult(null, lines);
            }
        }
        return null;
    }

    // MARK: - Cloud Code

    private async Task<ProbeOutcome> ProbeCloudCodeAsync(CancellationToken cancellationToken)
    {
        var stored = authStore.LoadCredentialToken();

        var tokens = new List<string>();
        if (stored?.AccessToken is { } access && authStore.IsUsable(stored.Expiry))
            tokens.Add(access);
        if (authStore.LoadCachedToken() is { } cached && !tokens.Contains(cached, StringComparer.Ordinal))
            tokens.Add(cached);

        // We have something to authenticate with if any token was tried or a refresh token exists.
        // Used to tell a transient outage ("temporarily unavailable") apart from "not signed in".
        var refreshToken = string.IsNullOrEmpty(stored?.RefreshToken) ? null : stored!.RefreshToken;
        var hasCredentials = tokens.Count > 0 || refreshToken is not null;

        var sawAuthFailure = false;
        foreach (var token in tokens)
        {
            var probe = await FetchCloudCodeAsync(token, cancellationToken);
            if (probe.Result is not null)
                return new ProbeOutcome(probe.Result);
            if (probe.Status == CloudCodeStatus.AuthFailed)
                sawAuthFailure = true;
        }

        // Only refresh on evidence of an auth failure (or no token to try) — a transient Cloud Code
        // outage must not trigger a Google OAuth refresh every cycle.
        if ((sawAuthFailure || tokens.Count == 0) && refreshToken is not null)
        {
            var refresh = await usageClient.RefreshGoogleTokenAsync(refreshToken, cancellationToken);
            switch (refresh.Status)
            {
                case TokenRefreshStatus.Refreshed when refresh.AccessToken is { } refreshed:
                    authStore.CacheToken(refreshed, refresh.ExpiresInSeconds);
                    var probe = await FetchCloudCodeAsync(refreshed, cancellationToken);
                    if (probe.Result is { } result)
                        return new ProbeOutcome(result);
                    // The refreshed token is valid, so a non-2xx is a transient outage, not bad auth.
                    return new ProbeOutcome(null, probe.Status == CloudCodeStatus.AuthFailed ? Failure.AuthExpired : Failure.Unavailable);
                // The refresh token itself is dead (revoked / expired) — expired auth, not an outage.
                case TokenRefreshStatus.AuthFailed:
                    return new ProbeOutcome(null, Failure.AuthExpired);
                // Refresh was only transiently unavailable (throttled / 5xx / network). The refresh
                // token may still be valid, so report a transient outage — even if a token 401'd, an
                // expired access token is normal and isn't evidence the sign-in is dead.
                default:
                    return new ProbeOutcome(null, Failure.Unavailable);
            }
        }

        // Reached only when no refresh was attempted (no refresh token): a rejected token with no way
        // to refresh is genuinely expired auth.
        if (sawAuthFailure)
            return new ProbeOutcome(null, Failure.AuthExpired);
        // Signed in but every endpoint was unreachable — a transient failure, not "not signed in".
        return new ProbeOutcome(null, hasCredentials ? Failure.Unavailable : Failure.NotSignedIn);
    }

    private sealed record CloudCodeProbe(CloudCodeStatus Status, StrategyResult? Result = null);

    private async Task<CloudCodeProbe> FetchCloudCodeAsync(string token, CancellationToken cancellationToken)
    {
        // Authoritative first: the quota summary (merged pools + weekly windows). A parsed summary —
        // even one with zero usable buckets — is the answer and must never fall into the legacy chain
        // below, which fabricates "fully used" from missing quota info. A 404 (build without the RPC)
        // reads as unavailable and falls through.
        var summary = await usageClient.CloudCodeAsync(
            AntigravityUsageClient.QuotaSummaryPath, token, "antigravity", EmptyBody, cancellationToken);
        if (summary.Status == CloudCodeStatus.AuthFailed)
            return new CloudCodeProbe(CloudCodeStatus.AuthFailed);
        if (summary is { Status: CloudCodeStatus.Ok, Body: { } summaryBody }
            && AntigravityUsageMapper.ParseQuotaSummary(summaryBody) is { } summaryLines)
        {
            return new CloudCodeProbe(
                CloudCodeStatus.Ok,
                new StrategyResult(await LoadPlanAsync(token, cancellationToken), summaryLines));
        }

        // Legacy: fetchAvailableModels — the full Antigravity model set (Gemini + Claude + GPT-OSS).
        var models = await usageClient.CloudCodeAsync(
            AntigravityUsageClient.FetchModelsPath, token, "antigravity", EmptyBody, cancellationToken);
        if (models.Status == CloudCodeStatus.AuthFailed)
            return new CloudCodeProbe(CloudCodeStatus.AuthFailed);
        if (models is { Status: CloudCodeStatus.Ok, Body: { } modelsBody })
        {
            var lines = AntigravityUsageMapper.BuildLines(AntigravityUsageMapper.ParseCloudCodeModels(modelsBody));
            if (lines.Count > 0)
            {
                return new CloudCodeProbe(
                    CloudCodeStatus.Ok,
                    new StrategyResult(await LoadPlanAsync(token, cancellationToken), lines));
            }
        }

        // Fallback: loadCodeAssist (plan + project) → retrieveUserQuota (Gemini-only buckets).
        string? plan = null;
        string? project = null;
        var load = await usageClient.CloudCodeAsync(
            AntigravityUsageClient.LoadCodeAssistPath, token, "agy", EmptyBody, cancellationToken);
        if (load.Status == CloudCodeStatus.AuthFailed)
            return new CloudCodeProbe(CloudCodeStatus.AuthFailed);
        if (load is { Status: CloudCodeStatus.Ok, Body: { } loadBody })
        {
            plan = AntigravityUsageMapper.ParseLoadCodeAssistPlan(loadBody);
            project = AntigravityUsageMapper.ParseProject(loadBody);
        }

        var quota = await usageClient.CloudCodeAsync(
            AntigravityUsageClient.RetrieveQuotaPath,
            token,
            "agy",
            project is null ? EmptyBody : new Dictionary<string, string> { ["project"] = project },
            cancellationToken);
        if (quota.Status == CloudCodeStatus.Unavailable && project is not null)
        {
            quota = await usageClient.CloudCodeAsync(
                AntigravityUsageClient.RetrieveQuotaPath, token, "agy", EmptyBody, cancellationToken);
        }
        if (quota.Status == CloudCodeStatus.AuthFailed)
            return new CloudCodeProbe(CloudCodeStatus.AuthFailed);
        if (quota is { Status: CloudCodeStatus.Ok, Body: { } quotaBody })
        {
            var lines = AntigravityUsageMapper.BuildLines(AntigravityUsageMapper.ParseQuotaBuckets(quotaBody));
            if (lines.Count > 0)
                return new CloudCodeProbe(CloudCodeStatus.Ok, new StrategyResult(plan, lines));
        }
        return new CloudCodeProbe(CloudCodeStatus.Unavailable);
    }

    private async Task<string?> LoadPlanAsync(string token, CancellationToken cancellationToken)
    {
        var load = await usageClient.CloudCodeAsync(
            AntigravityUsageClient.LoadCodeAssistPath, token, "agy", EmptyBody, cancellationToken);
        return load is { Status: CloudCodeStatus.Ok, Body: { } body }
            ? AntigravityUsageMapper.ParseLoadCodeAssistPlan(body)
            : null;
    }

    private static readonly IReadOnlyDictionary<string, string> EmptyBody = new Dictionary<string, string>();
}
