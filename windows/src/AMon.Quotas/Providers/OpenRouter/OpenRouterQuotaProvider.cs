using System.Text.Json;

namespace AMon.Quotas.Providers.OpenRouter;

public sealed class OpenRouterQuotaProvider(
    OpenRouterAuthStore authStore,
    OpenRouterUsageClient usageClient,
    IQuotaClock clock) : IQuotaProvider
{
    public const string MissingKeyMessage = "OpenRouter API 키가 없습니다. OPENROUTER_API_KEY 를 설정하거나 ~/.config/openrouter/key.json 에 저장해 주세요.";
    public const string InvalidKeyMessage = "OpenRouter API 키가 올바르지 않습니다.";

    public string Id => "openrouter";

    public string DisplayName => "OpenRouter";

    public Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken) =>
        Task.FromResult(authStore.LoadApiKey() is not null);

    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        if (authStore.LoadApiKey() is not { } auth)
            return QuotaSnapshot.Failure(this, MissingKeyMessage, clock.Now);

        // The two endpoints are fetched independently and only the one that answered is mapped:
        // `/credits` carries the balance and `/key` the tier plus period spend, and OpenRouter gates
        // them per key type, so one 403 must not erase the other's rows.
        using var credits = await LoadAsync(token => usageClient.FetchCreditsAsync(auth.ApiKey, token), cancellationToken);
        using var key = await LoadAsync(token => usageClient.FetchKeyAsync(auth.ApiKey, token), cancellationToken);

        var lines = new List<QuotaMetricLine>();
        string? plan = null;
        if (credits.Data is { } creditsData)
            lines.AddRange(OpenRouterUsageMapper.CreditsLines(creditsData));
        if (key.Data is { } keyData)
        {
            var (keyPlan, keyLines) = OpenRouterUsageMapper.KeyMetrics(keyData);
            plan = keyPlan;
            lines.AddRange(keyLines);
        }

        if (lines.Count > 0)
            return QuotaSnapshot.Success(this, plan, lines, clock.Now);

        // The key is only invalid when both endpoints rejected it; one rejection means the key is
        // valid but gated.
        if (credits.IsAuthFailure && key.IsAuthFailure)
            return QuotaSnapshot.Failure(this, InvalidKeyMessage, clock.Now);
        return QuotaSnapshot.Failure(
            this,
            credits.FailureMessage ?? key.FailureMessage ?? ProviderErrorText.InvalidResponse,
            clock.Now);
    }

    private static async Task<EndpointOutcome> LoadAsync(
        Func<CancellationToken, Task<QuotaHttpResponse>> call,
        CancellationToken cancellationToken)
    {
        QuotaHttpResponse response;
        try
        {
            response = await call(cancellationToken);
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return new EndpointOutcome { FailureMessage = ProviderErrorText.ConnectionFailed };
        }

        if (response.IsAuthFailure)
            return new EndpointOutcome { IsAuthFailure = true };
        if (!response.IsSuccess)
            return new EndpointOutcome { FailureMessage = ProviderErrorText.RequestFailed(response.StatusCode) };

        // OpenRouter wraps every payload in `{ "data": { … } }`.
        var document = QuotaJson.ParseObject(response.Body);
        if (document is null || QuotaJson.ObjectProperty(document.RootElement, "data") is not { } data)
        {
            document?.Dispose();
            return new EndpointOutcome { FailureMessage = ProviderErrorText.InvalidResponse };
        }
        return new EndpointOutcome { Document = document, Data = data };
    }

    /// One endpoint's outcome. Owns the parsed document so the mapped `data` element stays valid
    /// until both endpoints have been mapped.
    private sealed class EndpointOutcome : IDisposable
    {
        public JsonDocument? Document { get; init; }
        public JsonElement? Data { get; init; }
        public bool IsAuthFailure { get; init; }
        public string? FailureMessage { get; init; }

        public void Dispose() => Document?.Dispose();
    }
}
