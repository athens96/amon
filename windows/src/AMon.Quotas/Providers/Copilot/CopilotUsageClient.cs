namespace AMon.Quotas.Providers.Copilot;

/// Calls GitHub's internal Copilot usage endpoint with a GitHub OAuth token. Mirrors the headers the
/// official Copilot client sends; `Authorization` uses the `token` scheme (not `Bearer`), which is
/// what `/copilot_internal/user` accepts.
public sealed class CopilotUsageClient(IQuotaHttp http)
{
    public const string UsageUrl = "https://api.github.com/copilot_internal/user";

    public Task<QuotaHttpResponse> FetchUsageAsync(string token, CancellationToken cancellationToken) =>
        http.SendAsync(
            QuotaHttpRequest.Get(
                UsageUrl,
                new Dictionary<string, string>
                {
                    ["Authorization"] = $"token {token}",
                    ["Accept"] = "application/json",
                    ["Editor-Version"] = "vscode/1.96.2",
                    ["Editor-Plugin-Version"] = "copilot-chat/0.26.7",
                    ["User-Agent"] = "GitHubCopilotChat/0.26.7",
                    ["X-Github-Api-Version"] = "2025-04-01",
                },
                TimeSpan.FromSeconds(15)),
            cancellationToken);
}
