using System.Text.Json;

namespace AMon.Quotas.Providers.Antigravity;

/// The OAuth tokens Antigravity / the `agy` CLI already keep on the machine. Both write them through
/// go-keyring, whose Windows backend is Credential Manager: a generic credential whose target is
/// `service:user`, i.e. `gemini:antigravity`. The blob is JSON
/// `{ token: { access_token, refresh_token, expiry }, … }`, optionally wrapped in go-keyring's
/// `go-keyring-base64:` envelope (usually absent on Windows, tolerated anyway).
public sealed record AntigravityKeychainToken(string? AccessToken, string? RefreshToken, DateTimeOffset? Expiry);

public sealed class AntigravityAuthStore(
    IWindowsCredentialStore credentials,
    IQuotaFileSystem files,
    IQuotaEnvironment environment,
    IQuotaClock clock)
{
    /// go-keyring's Windows target for service `gemini`, user `antigravity`.
    public const string CredentialTarget = "gemini:antigravity";

    /// Treat a token with less than this left as already expired (skip straight to refresh).
    public static readonly TimeSpan RefreshBuffer = TimeSpan.FromSeconds(60);

    /// Our own cache of refreshed access tokens, so a Google OAuth refresh happens ~once per token
    /// lifetime instead of every refresh cycle. We never write back to Credential Manager.
    public string CachePath => environment.AppData("A-mon", "quota-cache", "antigravity-auth.json");

    public AntigravityKeychainToken? LoadCredentialToken()
    {
        try
        {
            var raw = credentials.ReadGenericCredential(CredentialTarget);
            return raw is null ? null : ExtractToken(raw);
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// Whether a stored access token is worth attempting: expiry unknown, or it hasn't passed yet.
    public bool IsUsable(DateTimeOffset? expiry) =>
        expiry is not { } value || value - clock.Now > RefreshBuffer;

    // MARK: - Refreshed-token cache

    public string? LoadCachedToken()
    {
        // Require at least `RefreshBuffer` of life left, matching `IsUsable` for the stored token — a
        // near-expiry cached token would otherwise yield a near-certain 401 and a wasteful refresh.
        try
        {
            if (!files.Exists(CachePath))
                return null;
            using var document = QuotaJson.ParseObject(files.ReadText(CachePath));
            if (document is null)
                return null;
            var token = QuotaJson.String(document.RootElement, "accessToken");
            var expiresAtMs = QuotaJson.Number(document.RootElement, "expiresAtMs");
            if (token is null || expiresAtMs is not { } expiry)
                return null;
            return expiry > clock.Now.ToUnixTimeMilliseconds() + RefreshBuffer.TotalMilliseconds ? token : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    public void CacheToken(string accessToken, double expiresInSeconds)
    {
        var expiresAtMs = clock.Now.ToUnixTimeMilliseconds() + expiresInSeconds * 1000;
        try
        {
            files.WriteText(CachePath, QuotaJson.Serialize(new Dictionary<string, object>
            {
                ["accessToken"] = accessToken,
                ["expiresAtMs"] = expiresAtMs,
            }));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // The refreshed token still works for this session; a failed cache only means we refresh
            // again next cycle.
        }
    }

    // MARK: - Token extraction (pure)

    /// Decode the credential value into tokens. Mirrors the `agy` format: an optional
    /// `go-keyring-base64:` wrapper around JSON `{ token: { access_token, … }, … }`, with fallbacks
    /// for a bare JSON string, a `Bearer …` value, or a raw token.
    public static AntigravityKeychainToken? ExtractToken(string raw)
    {
        if (GoKeyring.Unwrap(raw) is not { } text)
            return null;

        using (var document = QuotaJson.Parse(text))
        {
            if (document is not null)
            {
                if (document.RootElement.ValueKind == JsonValueKind.Object)
                    return TokenFromObject(document.RootElement);
                if (document.RootElement.ValueKind == JsonValueKind.String)
                {
                    var value = document.RootElement.GetString()?.Trim();
                    if (!string.IsNullOrEmpty(value))
                        return new AntigravityKeychainToken(value, null, null);
                }
            }
        }

        const string bearer = "Bearer ";
        if (text.StartsWith(bearer, StringComparison.Ordinal))
        {
            var token = text[bearer.Length..].Trim();
            return token.Length == 0 ? null : new AntigravityKeychainToken(token, null, null);
        }
        return new AntigravityKeychainToken(text, null, null);
    }

    public static AntigravityKeychainToken? TokenFromObject(JsonElement obj)
    {
        // Prefer a nested `token` object (the agy shape); otherwise read fields off the root.
        var source = QuotaJson.ObjectProperty(obj, "token") ?? obj;
        var access = QuotaJson.FirstString(
            source,
            "access_token", "accessToken", "token", "id_token", "idToken", "bearerToken", "auth_token", "authToken");
        var refresh = QuotaJson.FirstString(source, "refresh_token", "refreshToken");
        var expiry = QuotaTime.ParseIso8601(QuotaJson.FirstString(source, "expiry", "expires_at", "expiresAt"));

        if (access is null && refresh is null)
        {
            foreach (var key in NestedKeys)
            {
                if (QuotaJson.ObjectProperty(obj, key) is { } nested && TokenFromObject(nested) is { } token)
                    return token;
            }
            return null;
        }
        return new AntigravityKeychainToken(access, refresh, expiry);
    }

    private static readonly string[] NestedKeys = ["tokens", "oauth", "oauth2", "credentials", "auth"];
}
