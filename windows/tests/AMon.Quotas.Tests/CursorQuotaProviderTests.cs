using AMon.Quotas;
using AMon.Quotas.Providers.Cursor;

namespace AMon.Quotas.Tests;

public sealed class CursorQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    private sealed class FakeState(string? access, string? refresh, bool exists = true) : ICursorStateStore
    {
        public bool Exists => exists;
        public string? Persisted { get; private set; }

        public Task<CursorAuthTokens> ReadTokensAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new CursorAuthTokens(access, refresh));

        public Task TryPersistAccessTokenAsync(string accessToken, CancellationToken cancellationToken)
        {
            Persisted = accessToken;
            return Task.CompletedTask;
        }
    }

    [Fact]
    public async Task TeamSeatUsesTotalPercentUsed()
    {
        var http = new FakeHttp().On(
            CursorUsageClient.UsageUrl,
            200,
            """{"billingCycleEnd":1759363200000,"planUsage":{"totalPercentUsed":62.5,"autoPercentUsed":10}}""");
        var provider = new CursorQuotaProvider(new FakeState("tok", "ref"), new CursorUsageClient(http), new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(2, snapshot.Lines.Count);
        var total = Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]);
        Assert.Equal("Total usage", total.Label);
        Assert.Equal(62.5, total.Used);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1759363200000), total.ResetsAt);
    }

    [Fact]
    public async Task IndividualPlanDerivesPercentFromCentLimit()
    {
        var http = new FakeHttp().On(CursorUsageClient.UsageUrl, 200, """{"planUsage":{"limit":2000,"totalSpend":500}}""");
        var provider = new CursorQuotaProvider(new FakeState("tok", null), new CursorUsageClient(http), new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(25, Assert.IsType<QuotaProgressLine>(Assert.Single(snapshot.Lines)).Used);
    }

    [Fact]
    public async Task UnauthorizedRefreshesOnceAndPersistsToken()
    {
        var calls = 0;
        var http = new FakeHttp()
            .On(request => request.Url == CursorUsageClient.UsageUrl, _ => ++calls == 1
                ? FakeHttp.Response(401, "")
                : FakeHttp.Response(200, """{"planUsage":{"totalPercentUsed":1}}"""))
            .On(CursorUsageClient.RefreshUrl, 200, """{"access_token":"fresh"}""");
        var state = new FakeState("stale", "ref");
        var provider = new CursorQuotaProvider(state, new CursorUsageClient(http), new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("fresh", state.Persisted);
        Assert.Equal("Bearer fresh", http.Requests.Last().Headers!["Authorization"]);
    }

    [Fact]
    public async Task SecondUnauthorizedReportsExpiredSession()
    {
        var http = new FakeHttp()
            .On(CursorUsageClient.UsageUrl, 401, "")
            .On(CursorUsageClient.RefreshUrl, 200, """{"access_token":"fresh"}""");
        var provider = new CursorQuotaProvider(new FakeState("stale", "ref"), new CursorUsageClient(http), new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Contains("만료", snapshot.ErrorMessage);
    }

    [Fact]
    public async Task MissingStateDatabaseIsNotDetected()
    {
        var provider = new CursorQuotaProvider(new FakeState(null, null, exists: false), new CursorUsageClient(new FakeHttp()), new FixedQuotaClock(Now));

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        Assert.True((await provider.RefreshAsync(CancellationToken.None)).IsError);
    }

    [Fact]
    public async Task InstalledButSignedOutCursorIsNotDetected()
    {
        var provider = new CursorQuotaProvider(new FakeState(null, null), new CursorUsageClient(new FakeHttp()), new FixedQuotaClock(Now));

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
    }

    [Fact]
    public async Task RefreshTokenAloneCountsAsSignedIn()
    {
        var provider = new CursorQuotaProvider(new FakeState(null, "ref"), new CursorUsageClient(new FakeHttp()), new FixedQuotaClock(Now));

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
    }

    [Fact]
    public async Task ForbiddenIsReportedAsRequestFailureNotExpiredSession()
    {
        var http = new FakeHttp().On(CursorUsageClient.UsageUrl, 403, "");
        var provider = new CursorQuotaProvider(new FakeState("tok", "ref"), new CursorUsageClient(http), new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ProviderErrorText.RequestFailed(403), snapshot.ErrorMessage);
        Assert.DoesNotContain(http.Requests, static request => request.Url == CursorUsageClient.RefreshUrl);
    }

    [Fact]
    public void StateValuesAreJsonStringsOrBare()
    {
        Assert.Equal("abc", CursorStateStore.DecodeStateValue("\"abc\""));
        Assert.Equal("abc", CursorStateStore.DecodeStateValue("abc"));
        Assert.Null(CursorStateStore.DecodeStateValue(" "));
    }
}
