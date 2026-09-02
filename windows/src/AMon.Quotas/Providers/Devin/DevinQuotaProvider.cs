namespace AMon.Quotas.Providers.Devin;

public sealed class DevinQuotaProvider(
    DevinAuthStore authStore,
    DevinUsageClient usageClient,
    IQuotaClock clock) : IQuotaProvider
{
    public const string NotLoggedIn = "Devin 로그인이 필요합니다. devin auth login 을 실행해 주세요.";
    public const string QuotaUnavailable = "Devin 할당량 정보를 가져올 수 없습니다.";

    public string Id => "devin";

    public string DisplayName => "Devin";

    public Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken) =>
        Task.FromResult(authStore.LoadCredentialsFile() is not null || authStore.LoadAppAuth() is not null);

    /// Credentials file first; the app's stored auth only when it carries a different key or server.
    /// A 401/403 from any source outranks a plain "unavailable" in the final message, because a stale
    /// key is actionable and a transport hiccup is not.
    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        var sawApiKey = false;
        var sawAuthFailure = false;

        var credentials = authStore.LoadCredentialsFile();
        if (credentials is not null)
        {
            sawApiKey = true;
            var attempt = await AttemptAsync(credentials, cancellationToken);
            if (attempt.Usage is { } usage)
                return Snapshot(usage);
            sawAuthFailure |= attempt.IsAuthFailure;
        }

        var appAuth = authStore.LoadAppAuth();
        if (appAuth is not null && (credentials is null || ShouldAttemptAppAuth(appAuth, credentials)))
        {
            sawApiKey = true;
            var attempt = await AttemptAsync(appAuth, cancellationToken);
            if (attempt.Usage is { } usage)
                return Snapshot(usage);
            sawAuthFailure |= attempt.IsAuthFailure;
        }

        if (sawAuthFailure)
            return QuotaSnapshot.Failure(this, NotLoggedIn, clock.Now);
        return QuotaSnapshot.Failure(this, sawApiKey ? QuotaUnavailable : NotLoggedIn, clock.Now);
    }

    private async Task<DevinAttempt> AttemptAsync(DevinAuth auth, CancellationToken cancellationToken)
    {
        try
        {
            var response = await usageClient.FetchUserStatusAsync(auth, authStore.EffectiveApiServerUrl(auth), cancellationToken);
            if (response.IsAuthFailure)
                return DevinAttempt.AuthFailure;
            if (!response.IsSuccess)
                return DevinAttempt.Unavailable;

            using var document = QuotaJson.ParseObject(response.Body);
            return document is null
                ? DevinAttempt.Unavailable
                : new DevinAttempt(DevinUsageMapper.MapUserStatusResponse(document.RootElement), false);
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return DevinAttempt.Unavailable;
        }
    }

    private bool ShouldAttemptAppAuth(DevinAuth appAuth, DevinAuth credentials) =>
        !string.Equals(appAuth.ApiKey, credentials.ApiKey, StringComparison.Ordinal)
        || !string.Equals(
            authStore.EffectiveApiServerUrl(appAuth),
            authStore.EffectiveApiServerUrl(credentials),
            StringComparison.Ordinal);

    private QuotaSnapshot Snapshot(DevinMappedUsage mapped) =>
        QuotaSnapshot.Success(this, mapped.Plan, mapped.Lines, clock.Now);

    private readonly record struct DevinAttempt(DevinMappedUsage? Usage, bool IsAuthFailure)
    {
        public static DevinAttempt AuthFailure => new(null, true);

        public static DevinAttempt Unavailable => new(null, false);
    }
}
