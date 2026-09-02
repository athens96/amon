using System.Text.Json;

namespace AMon.Quotas.Providers.Cursor;

public sealed class CursorUsageClient(IQuotaHttp http)
{
    public const string UsageUrl = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
    public const string RefreshUrl = "https://api2.cursor.sh/oauth/token";
    private const string ClientId = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB";

    public Task<QuotaHttpResponse> FetchUsageAsync(string accessToken, CancellationToken cancellationToken) =>
        http.SendAsync(
            QuotaHttpRequest.PostJson(
                UsageUrl,
                "{}",
                new Dictionary<string, string>
                {
                    ["Authorization"] = $"Bearer {accessToken}",
                    ["Connect-Protocol-Version"] = "1",
                }),
            cancellationToken);

    /// Exchange the refresh token for a new access token; `null` on any failure.
    public async Task<string?> RefreshAccessTokenAsync(string refreshToken, CancellationToken cancellationToken)
    {
        var body = JsonSerializer.Serialize(new
        {
            grant_type = "refresh_token",
            client_id = ClientId,
            refresh_token = refreshToken,
        });
        var response = await http.SendAsync(QuotaHttpRequest.PostJson(RefreshUrl, body), cancellationToken);
        if (!response.IsSuccess)
            return null;
        using var document = QuotaJson.ParseObject(response.Body);
        return document is null ? null : QuotaJson.String(document.RootElement, "access_token");
    }
}
