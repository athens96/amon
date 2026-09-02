namespace AMon.Quotas.Providers.Copilot;

public sealed class CopilotQuotaProvider(
    CopilotAuthStore authStore,
    CopilotUsageClient usageClient,
    IQuotaClock clock) : IQuotaProvider
{
    public const string NotLoggedIn = "GitHub Copilot 로그인이 필요합니다.";
    public const string TokenInvalid = "GitHub 토큰이 만료되었습니다. gh auth login 으로 다시 로그인해 주세요.";

    public string Id => "copilot";

    public string DisplayName => "GitHub Copilot";

    public Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken) =>
        Task.FromResult(authStore.LoadTokenCandidates().Count > 0);

    /// `apps.json` can hold both old and new Copilot app tokens and some of them are expired, so the
    /// candidates are tried in order and the first one that authenticates wins — reading a single
    /// token makes 401s depend on which entry happened to be picked.
    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        var candidates = authStore.LoadTokenCandidates();
        if (candidates.Count == 0)
            return QuotaSnapshot.Failure(this, NotLoggedIn, clock.Now);

        try
        {
            foreach (var candidate in candidates)
            {
                var response = await usageClient.FetchUsageAsync(candidate.Value, cancellationToken);
                if (response.IsAuthFailure)
                    continue; // 만료/폐기된 후보 — 다음 토큰으로.
                if (!response.IsSuccess)
                    return QuotaSnapshot.Failure(this, ProviderErrorText.RequestFailed(response.StatusCode), clock.Now);

                using var document = QuotaJson.ParseObject(response.Body);
                if (document is null)
                    return QuotaSnapshot.Failure(this, ProviderErrorText.InvalidResponse, clock.Now);

                var mapped = CopilotUsageMapper.Map(document.RootElement);
                return mapped.ErrorMessage is { } message
                    ? QuotaSnapshot.Failure(this, message, clock.Now)
                    : QuotaSnapshot.Success(this, mapped.Plan, mapped.Lines, clock.Now);
            }

            // 모든 후보가 401/403 — 재로그인 필요.
            return QuotaSnapshot.Failure(this, TokenInvalid, clock.Now);
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return QuotaSnapshot.Failure(this, ProviderErrorText.ConnectionFailed, clock.Now);
        }
    }
}
