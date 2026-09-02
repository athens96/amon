namespace AMon.Quotas.Providers.OpenRouter;

public sealed class OpenRouterUsageClient(IQuotaHttp http)
{
    public const string CreditsUrl = "https://openrouter.ai/api/v1/credits";
    public const string KeyUrl = "https://openrouter.ai/api/v1/key";

    /// Account-wide credit balance and lifetime spend.
    public Task<QuotaHttpResponse> FetchCreditsAsync(string apiKey, CancellationToken cancellationToken) =>
        GetAsync(CreditsUrl, apiKey, cancellationToken);

    /// Key metadata: tier, optional per-key spend cap, and daily/weekly/monthly spend.
    public Task<QuotaHttpResponse> FetchKeyAsync(string apiKey, CancellationToken cancellationToken) =>
        GetAsync(KeyUrl, apiKey, cancellationToken);

    private Task<QuotaHttpResponse> GetAsync(string url, string apiKey, CancellationToken cancellationToken) =>
        http.SendAsync(
            QuotaHttpRequest.Get(
                url,
                new Dictionary<string, string>
                {
                    ["Authorization"] = $"Bearer {apiKey}",
                    ["Accept"] = "application/json",
                },
                TimeSpan.FromSeconds(15)),
            cancellationToken);
}
