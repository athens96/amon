namespace AMon.Quotas.Providers.Codex;

public sealed class CodexUsageClient(IQuotaHttp http)
{
    public const string UsageUrl = "https://chatgpt.com/backend-api/wham/usage";

    public Task<QuotaHttpResponse> FetchUsageAsync(CodexCredentials credentials, CancellationToken cancellationToken)
    {
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = $"Bearer {credentials.AccessToken}",
            ["Accept"] = "application/json",
            ["User-Agent"] = "amon",
        };
        if (credentials.AccountId is not null)
            headers["ChatGPT-Account-Id"] = credentials.AccountId;
        return http.SendAsync(QuotaHttpRequest.Get(UsageUrl, headers), cancellationToken);
    }
}
