namespace AMon.Quotas.Providers.Claude;

public sealed class ClaudeQuotaProvider(ClaudeAuthStore authStore, ClaudeUsageClient usageClient, IQuotaClock clock) : IQuotaProvider
{
    public string Id => "claude";

    public string DisplayName => "Claude Code";

    public Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken) =>
        Task.FromResult(authStore.Load() is not null);

    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        var credentials = authStore.Load();
        if (credentials is null)
        {
            return QuotaSnapshot.Failure(
                this,
                authStore.HasCredentialsFile ? "Claude OAuth 토큰을 찾지 못했습니다." : "Claude CLI 로그인이 필요합니다.",
                clock.Now);
        }

        try
        {
            var response = await usageClient.FetchUsageAsync(credentials.AccessToken, cancellationToken);
            if (response.IsAuthFailure)
                return QuotaSnapshot.Failure(this, "Claude 세션이 만료되었습니다. claude 에서 다시 로그인해 주세요.", clock.Now);
            if (!response.IsSuccess)
                return QuotaSnapshot.Failure(this, ProviderErrorText.RequestFailed(response.StatusCode), clock.Now);

            using var usage = QuotaJson.ParseObject(response.Body);
            if (usage is null)
                return QuotaSnapshot.Failure(this, ProviderErrorText.InvalidResponse, clock.Now);
            return QuotaSnapshot.Success(
                this,
                ClaudeUsageMapper.PlanName(credentials.SubscriptionType),
                ClaudeUsageMapper.Map(usage.RootElement),
                clock.Now);
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return QuotaSnapshot.Failure(this, ProviderErrorText.ConnectionFailed, clock.Now);
        }
    }
}
