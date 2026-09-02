using Microsoft.Data.Sqlite;

namespace AMon.Quotas.Providers.Cursor;

public sealed class CursorQuotaProvider(ICursorStateStore state, CursorUsageClient usageClient, IQuotaClock clock) : IQuotaProvider
{
    public string Id => "cursor";

    public string DisplayName => "Cursor";

    /// Detected only when Cursor is both installed and signed in — an installed-but-signed-out Cursor
    /// must disappear from the dashboard the same way a signed-out Claude or Codex does.
    public async Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken)
    {
        if (!state.Exists)
            return false;
        try
        {
            var tokens = await state.ReadTokensAsync(cancellationToken);
            return !string.IsNullOrWhiteSpace(tokens.AccessToken) || !string.IsNullOrWhiteSpace(tokens.RefreshToken);
        }
        catch (SqliteException)
        {
            return false;
        }
    }

    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        if (!state.Exists)
            return QuotaSnapshot.Failure(this, "Cursor 로그인이 필요합니다.", clock.Now);

        try
        {
            var auth = await state.ReadTokensAsync(cancellationToken);
            var token = auth.AccessToken;
            if (string.IsNullOrWhiteSpace(token) && !string.IsNullOrWhiteSpace(auth.RefreshToken))
                token = await usageClient.RefreshAccessTokenAsync(auth.RefreshToken, cancellationToken);
            if (string.IsNullOrWhiteSpace(token))
                return QuotaSnapshot.Failure(this, "Cursor 인증 토큰을 찾지 못했습니다.", clock.Now);

            var response = await ProviderAuthRetry.FetchAsync(
                token,
                usageClient.FetchUsageAsync,
                async ct =>
                {
                    if (string.IsNullOrWhiteSpace(auth.RefreshToken))
                        return null;
                    var refreshed = await usageClient.RefreshAccessTokenAsync(auth.RefreshToken, ct);
                    if (refreshed is not null)
                        await state.TryPersistAccessTokenAsync(refreshed, ct);
                    return refreshed;
                },
                cancellationToken,
                // Cursor answers 403 for plan/permission problems, not expired sessions; only a 401
                // is worth a token refresh, matching the previous in-app behavior.
                static response => response.StatusCode == 401);
            if (response is null)
                return QuotaSnapshot.Failure(this, "Cursor 세션이 만료되었습니다. Cursor 앱에서 다시 로그인해 주세요.", clock.Now);
            if (!response.IsSuccess)
                return QuotaSnapshot.Failure(this, ProviderErrorText.RequestFailed(response.StatusCode), clock.Now);

            using var usage = QuotaJson.ParseObject(response.Body);
            if (usage is null)
                return QuotaSnapshot.Failure(this, ProviderErrorText.InvalidResponse, clock.Now);
            return QuotaSnapshot.Success(this, null, CursorUsageMapper.Map(usage.RootElement), clock.Now);
        }
        catch (SqliteException)
        {
            return QuotaSnapshot.Failure(this, ProviderErrorText.LocalCredentialsUnreadable, clock.Now);
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return QuotaSnapshot.Failure(this, ProviderErrorText.ConnectionFailed, clock.Now);
        }
    }
}
