namespace AMon.Quotas.Providers.ZAI;

public sealed class ZaiQuotaProvider(ZaiAuthStore authStore, ZaiUsageClient usageClient, IQuotaClock clock) : IQuotaProvider
{
    public const string MissingKeyMessage = "Z.ai API 키가 없습니다. ZAI_API_KEY 를 설정하거나 ~/.config/zai/key.json 에 저장해 주세요.";
    public const string InvalidKeyMessage = "Z.ai API 키가 올바르지 않습니다.";
    public const string NoCodingPlanMessage = "활성화된 GLM Coding Plan 이 없습니다.";

    public string Id => "zai";

    public string DisplayName => "Z.ai";

    public Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken) =>
        Task.FromResult(authStore.LoadApiKey() is not null);

    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        if (authStore.LoadApiKey() is not { } auth)
            return QuotaSnapshot.Failure(this, MissingKeyMessage, clock.Now);

        // The quota endpoint is required; the subscription endpoint is best-effort (plan name only),
        // so a failure there must not blank out the meters.
        var (body, isAuthFailure, failureMessage) =
            await LoadQuotaAsync(auth.ApiKey, cancellationToken);
        if (isAuthFailure)
            return QuotaSnapshot.Failure(this, InvalidKeyMessage, clock.Now);
        if (body is null)
            return QuotaSnapshot.Failure(this, failureMessage ?? ProviderErrorText.InvalidResponse, clock.Now);

        // A valid key whose account has no GLM Coding Plan gets a 2xx with `success:false`. Say so
        // rather than showing blank meters that don't explain why nothing's there.
        if (ZaiUsageMapper.IsNoCodingPlan(body))
            return QuotaSnapshot.Failure(this, NoCodingPlanMessage, clock.Now);

        var plan = ZaiUsageMapper.PlanName(await LoadSubscriptionAsync(auth.ApiKey, cancellationToken));
        return QuotaSnapshot.Success(this, plan, ZaiUsageMapper.MapQuota(body), clock.Now);
    }

    private async Task<(string? Body, bool IsAuthFailure, string? FailureMessage)> LoadQuotaAsync(
        string apiKey,
        CancellationToken cancellationToken)
    {
        try
        {
            var response = await usageClient.FetchQuotaAsync(apiKey, cancellationToken);
            if (response.IsAuthFailure)
                return (null, true, null);
            return response.IsSuccess
                ? (response.Body, false, null)
                : (null, false, ProviderErrorText.RequestFailed(response.StatusCode));
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return (null, false, ProviderErrorText.ConnectionFailed);
        }
    }

    /// Never fails into the snapshot: a transport error, a non-2xx, or an auth failure all just mean
    /// "no plan name this refresh".
    private async Task<string?> LoadSubscriptionAsync(string apiKey, CancellationToken cancellationToken)
    {
        try
        {
            var response = await usageClient.FetchSubscriptionAsync(apiKey, cancellationToken);
            return response.IsSuccess ? response.Body : null;
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return null;
        }
    }
}
