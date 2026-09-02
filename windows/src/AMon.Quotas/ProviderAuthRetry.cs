using System.Net.Http;

namespace AMon.Quotas;

/// The authenticated-fetch sequence every OAuth-style provider shares: attempt → on 401/403 refresh
/// the token → retry once → a second 401/403 is a hard auth failure. Anything that isn't an auth
/// failure (success, 429, 5xx) is returned untouched for the provider to interpret.
public static class ProviderAuthRetry
{
    public static bool IsAuthFailure(QuotaHttpResponse response) => response.IsAuthFailure;

    /// - `attempt` performs the request with the given token; called at most twice.
    /// - `refreshAccessToken` returns a fresh token or `null` when refreshing is impossible.
    /// Returns the final response, or `null` when the retried request still came back 401/403.
    /// Throws `HttpRequestException` when the transport itself fails.
    public static async Task<QuotaHttpResponse?> FetchAsync(
        string token,
        Func<string, CancellationToken, Task<QuotaHttpResponse>> attempt,
        Func<CancellationToken, Task<string?>> refreshAccessToken,
        CancellationToken cancellationToken,
        Func<QuotaHttpResponse, bool>? isAuthFailure = null)
    {
        isAuthFailure ??= IsAuthFailure;
        var response = await attempt(token, cancellationToken);
        if (!isAuthFailure(response))
            return response;

        var refreshed = await refreshAccessToken(cancellationToken);
        if (string.IsNullOrWhiteSpace(refreshed))
            return null;

        var retried = await attempt(refreshed, cancellationToken);
        return isAuthFailure(retried) ? null : retried;
    }

    public static bool IsTransportFailure(Exception exception) =>
        exception is HttpRequestException or IOException or TaskCanceledException;
}
