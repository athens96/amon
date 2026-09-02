namespace AMon.Quotas.Providers.Claude;

public sealed class ClaudeUsageClient(IQuotaHttp http)
{
    public const string UsageUrl = "https://api.anthropic.com/api/oauth/usage";

    public Task<QuotaHttpResponse> FetchUsageAsync(string accessToken, CancellationToken cancellationToken) =>
        http.SendAsync(
            QuotaHttpRequest.Get(
                UsageUrl,
                new Dictionary<string, string>
                {
                    ["Authorization"] = $"Bearer {accessToken}",
                    ["Accept"] = "application/json",
                    ["anthropic-beta"] = "oauth-2025-04-20",
                    ["User-Agent"] = "claude-code/2.1.69",
                }),
            cancellationToken);
}
