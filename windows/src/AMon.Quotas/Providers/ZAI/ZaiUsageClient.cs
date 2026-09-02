namespace AMon.Quotas.Providers.ZAI;

public sealed class ZaiUsageClient(IQuotaHttp http)
{
    public const string QuotaUrl = "https://api.z.ai/api/monitor/usage/quota/limit";
    public const string SubscriptionUrl = "https://api.z.ai/api/biz/subscription/list";

    /// Session token usage and web-search quotas. Required for a usable snapshot.
    public Task<QuotaHttpResponse> FetchQuotaAsync(string apiKey, CancellationToken cancellationToken) =>
        GetAsync(QuotaUrl, apiKey, cancellationToken);

    /// The active subscription(s) — best-effort, used only to surface the plan name.
    public Task<QuotaHttpResponse> FetchSubscriptionAsync(string apiKey, CancellationToken cancellationToken) =>
        GetAsync(SubscriptionUrl, apiKey, cancellationToken);

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
