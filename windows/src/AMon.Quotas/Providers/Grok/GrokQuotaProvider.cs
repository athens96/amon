namespace AMon.Quotas.Providers.Grok;

public sealed class GrokQuotaProvider(GrokAuthStore authStore, GrokUsageClient usageClient, IQuotaClock clock) : IQuotaProvider
{
    public const string NotLoggedInMessage = "Grok 로그인이 필요합니다. grok login 을 실행해 주세요.";
    public const string InvalidAuthMessage = "Grok 인증 정보가 올바르지 않습니다. grok login 을 다시 실행해 주세요.";
    public const string ExpiredMessage = "Grok 인증이 만료되었습니다. grok login 을 다시 실행해 주세요.";
    public const string InvalidResponseMessage = "Grok 청구 응답 형식이 바뀌었습니다.";

    public string Id => "grok";

    public string DisplayName => "Grok";

    public Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken) =>
        Task.FromResult(authStore.LoadAuthCandidates(out _).Count > 0);

    public async Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        var candidates = authStore.LoadAuthCandidates(out var failure);
        if (candidates.Count == 0)
        {
            return QuotaSnapshot.Failure(
                this,
                failure == GrokAuthFailure.NotLoggedIn ? NotLoggedInMessage : InvalidAuthMessage,
                clock.Now);
        }

        try
        {
            // Refresh-before-use for a candidate inside the expiry buffer; a candidate that is both
            // unrefreshable and already expired is skipped so a second account can still answer.
            var sawExpiredCandidate = false;
            foreach (var state in candidates)
            {
                if (authStore.NeedsRefresh(state.Entry, state.Token))
                {
                    if (await RefreshAccessTokenAsync(state, cancellationToken) is { } refreshed)
                        return await ProbeAsync(state, refreshed, cancellationToken);
                    if (authStore.IsExpired(state.Entry, state.Token))
                    {
                        sawExpiredCandidate = true;
                        continue;
                    }
                }
                return await ProbeAsync(state, state.Token, cancellationToken);
            }

            return QuotaSnapshot.Failure(this, sawExpiredCandidate ? ExpiredMessage : InvalidAuthMessage, clock.Now);
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return QuotaSnapshot.Failure(this, ProviderErrorText.ConnectionFailed, clock.Now);
        }
    }

    private async Task<QuotaSnapshot> ProbeAsync(GrokAuthState state, string accessToken, CancellationToken cancellationToken)
    {
        var billing = await ProviderAuthRetry.FetchAsync(
            accessToken,
            (token, cancellation) => usageClient.FetchBillingAsync(token, cancellation),
            cancellation => RefreshAccessTokenAsync(state, cancellation),
            cancellationToken);
        if (billing is null || billing.IsAuthFailure)
            return QuotaSnapshot.Failure(this, ExpiredMessage, clock.Now);
        if (!billing.IsSuccess)
            return QuotaSnapshot.Failure(this, ProviderErrorText.RequestFailed(billing.StatusCode), clock.Now);

        using var document = QuotaJson.ParseObject(billing.Body);
        if (document is null || GrokUsageMapper.MapBilling(document.RootElement) is not { } lines)
            return QuotaSnapshot.Failure(this, InvalidResponseMessage, clock.Now);

        return QuotaSnapshot.Success(this, await FetchPlanNameAsync(state.Token, cancellationToken), lines, clock.Now);
    }

    /// Rotates the credential in place and persists it. `null` for every failure mode — no refresh
    /// token, a transport error, a non-2xx, or an undecodable body — which the caller reads as
    /// "this candidate can't be revived".
    private async Task<string?> RefreshAccessTokenAsync(GrokAuthState state, CancellationToken cancellationToken)
    {
        if (authStore.RefreshTokenFor(state.Entry) is not { } refreshToken)
            return null;

        QuotaHttpResponse response;
        try
        {
            response = await usageClient.RefreshTokenAsync(
                refreshToken,
                authStore.ClientId(state.EntryKey, state.Entry),
                cancellationToken);
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return null;
        }

        if (!response.IsSuccess || GrokUsageClient.DecodeRefreshResponse(response) is not { } decoded)
            return null;

        var accessToken = decoded.AccessToken.Trim();
        if (accessToken.Length == 0)
            return null;

        state.Token = accessToken;
        state.Entry.Key = accessToken;
        if (decoded.RefreshToken?.Trim() is { Length: > 0 } rotatedRefresh)
            state.Entry.RefreshToken = rotatedRefresh;
        if (decoded.IdToken?.Trim() is { Length: > 0 } rotatedId)
            state.Entry.IdToken = rotatedId;
        state.Entry.ExpiresAt = QuotaTime.ToIso8601(ExpiryDate(decoded, accessToken));
        // A failed save only strands the rotated token on disk; the token itself works for this
        // session, so keep going rather than failing the live fetch.
        authStore.Save(state);
        return accessToken;
    }

    private DateTimeOffset ExpiryDate(GrokRefreshResponse response, string accessToken)
    {
        if (response.ExpiresIn is { } expiresIn && double.IsFinite(expiresIn) && expiresIn > 0)
            return clock.Now.AddSeconds(expiresIn);
        return authStore.TokenExpiresAt(accessToken) ?? clock.Now.AddHours(1);
    }

    private async Task<string?> FetchPlanNameAsync(string accessToken, CancellationToken cancellationToken)
    {
        try
        {
            return GrokUsageMapper.PlanName(await usageClient.FetchSettingsAsync(accessToken, cancellationToken));
        }
        catch (Exception exception) when (ProviderAuthRetry.IsTransportFailure(exception))
        {
            return null;
        }
    }
}
