namespace AMon.Quotas.Providers.Codex;

public sealed class CodexQuotaProvider(CodexAuthStore authStore, CodexUsageClient usageClient, IQuotaClock clock) : IQuotaProvider
{
    public string Id => "codex";

    public string DisplayName => "Codex";

    public Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken) =>
        Task.FromResult(authStore.Load() is not null);

    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        var credentials = authStore.Load();
        if (credentials is null)
        {
            return QuotaSnapshot.Failure(
                this,
                authStore.HasAuthFile ? "Codex OAuth 토큰을 찾지 못했습니다." : "Codex 로그인이 필요합니다.",
                clock.Now);
        }

        try
        {
            var response = await usageClient.FetchUsageAsync(credentials, cancellationToken);
            if (response.IsAuthFailure)
                return QuotaSnapshot.Failure(this, "Codex 세션이 만료되었습니다. codex login 으로 다시 로그인해 주세요.", clock.Now);
            if (!response.IsSuccess)
                return QuotaSnapshot.Failure(this, ProviderErrorText.RequestFailed(response.StatusCode), clock.Now);

            using var usage = QuotaJson.ParseObject(response.Body);
            if (usage is null)
                return QuotaSnapshot.Failure(this, ProviderErrorText.InvalidResponse, clock.Now);
            return QuotaSnapshot.Success(
                this,
                CodexUsageMapper.PlanName(usage.RootElement),
                CodexUsageMapper.Map(usage.RootElement),
                clock.Now);
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return QuotaSnapshot.Failure(this, ProviderErrorText.ConnectionFailed, clock.Now);
        }
    }
}
