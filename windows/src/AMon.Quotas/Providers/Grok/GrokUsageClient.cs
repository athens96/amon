namespace AMon.Quotas.Providers.Grok;

/// The fields the xAI token endpoint returns on a successful refresh.
public sealed record GrokRefreshResponse(string AccessToken, string? RefreshToken, string? IdToken, double? ExpiresIn);

public sealed class GrokUsageClient(IQuotaHttp http)
{
    public const string BillingUrl = "https://cli-chat-proxy.grok.com/v1/billing";
    public const string SettingsUrl = "https://cli-chat-proxy.grok.com/v1/settings";
    public const string RefreshUrl = "https://auth.x.ai/oauth2/token";
    public const string TokenAuthHeader = "xai-grok-cli";

    public Task<QuotaHttpResponse> RefreshTokenAsync(string refreshToken, string clientId, CancellationToken cancellationToken)
    {
        var body =
            "grant_type=refresh_token"
            + $"&client_id={Uri.EscapeDataString(clientId)}"
            + $"&refresh_token={Uri.EscapeDataString(refreshToken)}";
        return http.SendAsync(
            QuotaHttpRequest.PostForm(RefreshUrl, body, timeout: TimeSpan.FromSeconds(15)),
            cancellationToken);
    }

    public Task<QuotaHttpResponse> FetchBillingAsync(string accessToken, CancellationToken cancellationToken) =>
        http.SendAsync(
            QuotaHttpRequest.Get(BillingUrl, AuthHeaders(accessToken), TimeSpan.FromSeconds(10)),
            cancellationToken);

    public Task<QuotaHttpResponse> FetchSettingsAsync(string accessToken, CancellationToken cancellationToken) =>
        http.SendAsync(
            QuotaHttpRequest.Get(SettingsUrl, AuthHeaders(accessToken), TimeSpan.FromSeconds(10)),
            cancellationToken);

    public static GrokRefreshResponse? DecodeRefreshResponse(QuotaHttpResponse response)
    {
        using var document = QuotaJson.ParseObject(response.Body);
        if (document is null || QuotaJson.String(document.RootElement, "access_token") is not { } accessToken)
            return null;
        var root = document.RootElement;
        return new GrokRefreshResponse(
            accessToken,
            QuotaJson.String(root, "refresh_token"),
            QuotaJson.String(root, "id_token"),
            QuotaJson.Number(root, "expires_in"));
    }

    private static Dictionary<string, string> AuthHeaders(string accessToken) => new()
    {
        ["Authorization"] = $"Bearer {accessToken.Trim()}",
        ["X-XAI-Token-Auth"] = TokenAuthHeader,
        ["Accept"] = "application/json",
        ["User-Agent"] = "OpenUsage",
    };
}
