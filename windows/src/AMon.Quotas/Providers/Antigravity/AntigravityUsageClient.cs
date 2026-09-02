using System.Globalization;
using System.Text;

namespace AMon.Quotas.Providers.Antigravity;

/// Outcome of a Cloud Code call, split so the orchestrator can tell a genuine auth failure (refresh)
/// apart from a transient outage (try the next base URL / strategy, don't refresh).
public enum CloudCodeStatus
{
    Ok,
    AuthFailed,
    Unavailable,
}

public sealed record CloudCodeOutcome(CloudCodeStatus Status, string? Body = null)
{
    public static readonly CloudCodeOutcome AuthFailed = new(CloudCodeStatus.AuthFailed);
    public static readonly CloudCodeOutcome Unavailable = new(CloudCodeStatus.Unavailable);

    public static CloudCodeOutcome Ok(string body) => new(CloudCodeStatus.Ok, body);
}

/// Result of a Google OAuth token refresh, split so a dead refresh token reads as expired auth while
/// a 5xx/network failure reads as a transient outage.
public enum TokenRefreshStatus
{
    Refreshed,
    AuthFailed,
    Unavailable,
}

public sealed record TokenRefreshOutcome(TokenRefreshStatus Status, string? AccessToken = null, double ExpiresInSeconds = 0)
{
    public static readonly TokenRefreshOutcome AuthFailed = new(TokenRefreshStatus.AuthFailed);
    public static readonly TokenRefreshOutcome Unavailable = new(TokenRefreshStatus.Unavailable);

    public static TokenRefreshOutcome Refreshed(string accessToken, double expiresInSeconds) =>
        new(TokenRefreshStatus.Refreshed, accessToken, expiresInSeconds);
}

/// All network I/O for Antigravity: the local language-server RPC (loopback HTTPS, self-signed), the
/// Google Cloud Code endpoints, and the Google OAuth token refresh.
public sealed class AntigravityUsageClient(IQuotaHttp lsHttp, IQuotaHttp http, IQuotaEnvironment environment)
{
    public const string LsService = "exa.language_server_pb.LanguageServerService";
    public const string FetchModelsPath = "/v1internal:fetchAvailableModels";
    public const string LoadCodeAssistPath = "/v1internal:loadCodeAssist";
    public const string RetrieveQuotaPath = "/v1internal:retrieveUserQuota";
    public const string QuotaSummaryPath = "/v1internal:retrieveUserQuotaSummary";
    public const string GoogleOAuthUrl = "https://oauth2.googleapis.com/token";
    public const string ClientIdVariable = "AMON_GOOGLE_OAUTH_CLIENT_ID";
    public const string ClientSecretVariable = "AMON_GOOGLE_OAUTH_CLIENT_SECRET";

    public static readonly IReadOnlyList<string> CloudCodeUrls =
    [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com",
    ];

    private static readonly TimeSpan LsTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan RemoteTimeout = TimeSpan.FromSeconds(15);

    private static readonly string LsRequestBody = QuotaJson.Serialize(new Dictionary<string, object>
    {
        ["metadata"] = new Dictionary<string, string>
        {
            ["ideName"] = "antigravity",
            ["extensionName"] = "antigravity",
            ["ideVersion"] = "unknown",
            ["locale"] = "en",
        },
    });

    /// Call a language-server RPC method. Returns null on a transport failure (port not the live one).
    public async Task<QuotaHttpResponse?> CallLSAsync(
        string scheme,
        int port,
        string csrf,
        string method,
        CancellationToken cancellationToken)
    {
        var request = QuotaHttpRequest.PostJson(
            $"{scheme}://127.0.0.1:{port}/{LsService}/{method}",
            LsRequestBody,
            new Dictionary<string, string>
            {
                ["Connect-Protocol-Version"] = "1",
                ["x-codeium-csrf-token"] = csrf,
            },
            LsTimeout);
        try
        {
            return await lsHttp.SendAsync(request, cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return null;
        }
    }

    /// POST a Cloud Code endpoint, trying each base URL in turn. A 401/403 short-circuits to
    /// `AuthFailed` (the same token would fail on the other base); other non-2xx / transport errors
    /// fall through to the next base and finally `Unavailable`.
    public async Task<CloudCodeOutcome> CloudCodeAsync(
        string path,
        string token,
        string userAgent,
        IReadOnlyDictionary<string, string> body,
        CancellationToken cancellationToken)
    {
        var payload = QuotaJson.Serialize(body);
        foreach (var baseUrl in CloudCodeUrls)
        {
            var request = QuotaHttpRequest.PostJson(
                baseUrl + path,
                payload,
                new Dictionary<string, string>
                {
                    ["Accept"] = "application/json",
                    ["Authorization"] = $"Bearer {token}",
                    ["User-Agent"] = userAgent,
                },
                RemoteTimeout);
            QuotaHttpResponse response;
            try
            {
                response = await http.SendAsync(request, cancellationToken);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                continue;
            }
            if (response.IsAuthFailure)
                return CloudCodeOutcome.AuthFailed;
            if (response.IsSuccess)
                return CloudCodeOutcome.Ok(response.Body);
        }
        return CloudCodeOutcome.Unavailable;
    }

    /// Exchange a Google refresh token for a fresh access token. Distinguishes a dead refresh token
    /// (4xx, e.g. `invalid_grant`) from a transient failure (5xx / network / undecodable) so the
    /// caller can report "sign-in expired" vs "temporarily unavailable" correctly.
    public async Task<TokenRefreshOutcome> RefreshGoogleTokenAsync(string refreshToken, CancellationToken cancellationToken)
    {
        // OAuth credentials must be supplied by the runtime environment. Keeping them out of source
        // avoids coupling amon to credentials extracted from another installed application.
        var clientId = environment.Variable(ClientIdVariable);
        var clientSecret = environment.Variable(ClientSecretVariable);
        if (string.IsNullOrEmpty(clientId) || string.IsNullOrEmpty(clientSecret))
            return TokenRefreshOutcome.Unavailable;

        var form = string.Join('&', [
            $"client_id={FormEncoded(clientId)}",
            $"client_secret={FormEncoded(clientSecret)}",
            $"refresh_token={FormEncoded(refreshToken)}",
            "grant_type=refresh_token",
        ]);
        QuotaHttpResponse response;
        try
        {
            response = await http.SendAsync(QuotaHttpRequest.PostForm(GoogleOAuthUrl, form, null, RemoteTimeout), cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return TokenRefreshOutcome.Unavailable;
        }

        if (response.IsSuccess)
        {
            using var document = QuotaJson.ParseObject(response.Body);
            if (document is null || QuotaJson.String(document.RootElement, "access_token") is not { } access)
                return TokenRefreshOutcome.Unavailable; // 2xx but undecodable / empty — treat as transient
            return TokenRefreshOutcome.Refreshed(access, QuotaJson.Number(document.RootElement, "expires_in") ?? 3600);
        }
        return response.StatusCode switch
        {
            // request timeout / rate limited — transient, not a revoked token
            408 or 429 => TokenRefreshOutcome.Unavailable,
            // invalid_grant / invalid_client — refresh token revoked or expired
            >= 400 and < 500 => TokenRefreshOutcome.AuthFailed,
            // 5xx and anything else — transient
            _ => TokenRefreshOutcome.Unavailable,
        };
    }

    /// Conservative: refresh tokens contain `/`, so encode everything but alphanumerics.
    private static string FormEncoded(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            if (char.IsAsciiLetterOrDigit((char)b))
                builder.Append((char)b);
            else
                builder.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return builder.ToString();
    }
}
