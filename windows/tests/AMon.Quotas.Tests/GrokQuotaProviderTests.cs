using System.Text;
using System.Text.Json;
using AMon.Quotas;
using AMon.Quotas.Providers.Grok;

namespace AMon.Quotas.Tests;

public sealed class GrokQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    private const string Billing = """
        {"config":{"used":{"val":25},"monthlyLimit":{"val":100},
        "billingPeriodEnd":"2026-09-30T00:00:00Z","onDemandCap":{"val":50}}}
        """;

    private static string AuthPath(FakeEnvironment environment) =>
        Path.Combine(environment.HomeDirectory, ".grok", "auth.json");

    private static GrokQuotaProvider Provider(FakeFileSystem files, FakeEnvironment environment, FakeHttp http, IQuotaClock clock) =>
        new(new GrokAuthStore(files, environment, clock), new GrokUsageClient(http), clock);

    private static string BodyText(QuotaHttpRequest request) =>
        request.Body is null ? string.Empty : Encoding.UTF8.GetString(request.Body);

    private static bool BearerIs(QuotaHttpRequest request, string token) =>
        request.Headers is { } headers
        && headers.TryGetValue("Authorization", out var value)
        && value == $"Bearer {token}";

    [Fact]
    public async Task MapsBillingAndPlan()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] =
            """{"acct::client-1":{"key":"tok-live","expires_at":"2026-09-05T00:00:00Z"}}""";
        var http = new FakeHttp()
            .On(GrokUsageClient.BillingUrl, 200, Billing)
            .On(GrokUsageClient.SettingsUrl, 200, """{"subscription_tier_display":"SuperGrok"}""");
        var provider = Provider(files, environment, http, new FixedQuotaClock(Now));

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("SuperGrok", snapshot.Plan);
        Assert.Equal(2, snapshot.Lines.Count);
        var credits = Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]);
        Assert.Equal("Credits used", credits.Label);
        Assert.Equal(25, credits.Used);
        Assert.Equal(QuotaMetricKind.Percent, credits.Kind);
        Assert.Equal(new DateTimeOffset(2026, 9, 30, 0, 0, 0, TimeSpan.Zero), credits.ResetsAt);
        var payAsYouGo = Assert.IsType<QuotaBadgeLine>(snapshot.Lines[1]);
        Assert.Equal("Pay as you go", payAsYouGo.Label);
        Assert.Equal("50 cap", payAsYouGo.Text);

        var billingRequest = http.Requests[0];
        Assert.True(BearerIs(billingRequest, "tok-live"));
        Assert.Equal("xai-grok-cli", billingRequest.Headers!["X-XAI-Token-Auth"]);
        Assert.Equal("OpenUsage", billingRequest.Headers!["User-Agent"]);
    }

    [Fact]
    public async Task MissingOnDemandCapBecomesDisabledBadge()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] = """{"acct":{"key":"tok-live"}}""";
        var http = new FakeHttp()
            .On(
                GrokUsageClient.BillingUrl,
                200,
                """{"config":{"used":{"val":10},"monthlyLimit":{"val":40},"billingPeriodEnd":"2026-09-30T00:00:00Z"}}""")
            .On(GrokUsageClient.SettingsUrl, 500, "{}");
        var provider = Provider(files, environment, http, new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Null(snapshot.Plan);
        Assert.Equal(25, Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]).Used);
        Assert.Equal("Disabled", Assert.IsType<QuotaBadgeLine>(snapshot.Lines[1]).Text);
    }

    [Fact]
    public async Task MissingAuthFileIsNotDetected()
    {
        var provider = Provider(new FakeFileSystem(), new FakeEnvironment(), new FakeHttp(), new FixedQuotaClock(Now));

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(GrokQuotaProvider.NotLoggedInMessage, snapshot.ErrorMessage);
        Assert.Empty(snapshot.Lines);
    }

    [Fact]
    public async Task AuthFileWithoutKeyedEntryIsInvalid()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] = """{"acct":{"refresh_token":"r"}}""";
        var provider = Provider(files, environment, new FakeHttp(), new FixedQuotaClock(Now));

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        Assert.Equal(
            GrokQuotaProvider.InvalidAuthMessage,
            (await provider.RefreshAsync(CancellationToken.None)).ErrorMessage);
    }

    [Fact]
    public async Task NearExpiryRefreshesBeforeProbing()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] =
            """{"acct::client-9":{"key":"tok-old","refresh_token":"refresh-old","expires_at":"2026-09-02T12:01:00Z"}}""";
        var http = new FakeHttp()
            .On(
                GrokUsageClient.RefreshUrl,
                200,
                """{"access_token":"tok-new","refresh_token":"refresh-new","expires_in":3600}""")
            .On(request => request.Url == GrokUsageClient.BillingUrl && BearerIs(request, "tok-new"), _ => FakeHttp.Response(200, Billing))
            .On(GrokUsageClient.SettingsUrl, 200, "{}");
        var provider = Provider(files, environment, http, new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        var refreshBody = BodyText(http.Requests[0]);
        Assert.Contains("grant_type=refresh_token", refreshBody, StringComparison.Ordinal);
        Assert.Contains("client_id=client-9", refreshBody, StringComparison.Ordinal);
        Assert.Contains("refresh_token=refresh-old", refreshBody, StringComparison.Ordinal);

        using var saved = JsonDocument.Parse(files.Files[AuthPath(environment)]);
        var entry = saved.RootElement.GetProperty("acct::client-9");
        Assert.Equal("tok-new", entry.GetProperty("key").GetString());
        Assert.Equal("refresh-new", entry.GetProperty("refresh_token").GetString());
        Assert.Equal("2026-09-02T13:00:00.000Z", entry.GetProperty("expires_at").GetString());
    }

    [Fact]
    public async Task UnauthorizedBillingRefreshesAndRetriesOnce()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] =
            """{"acct":{"key":"tok-old","refresh":"refresh-old","expires_at":"2026-09-05T00:00:00Z"}}""";
        var http = new FakeHttp()
            .On(request => request.Url == GrokUsageClient.BillingUrl && BearerIs(request, "tok-old"), _ => FakeHttp.Response(401, ""))
            .On(GrokUsageClient.RefreshUrl, 200, """{"access_token":"tok-new"}""")
            .On(request => request.Url == GrokUsageClient.BillingUrl && BearerIs(request, "tok-new"), _ => FakeHttp.Response(200, Billing))
            .On(GrokUsageClient.SettingsUrl, 200, "{}");
        var provider = Provider(files, environment, http, new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal(
            new[] { GrokUsageClient.BillingUrl, GrokUsageClient.RefreshUrl, GrokUsageClient.BillingUrl, GrokUsageClient.SettingsUrl },
            http.Requests.Select(request => request.Url).ToArray());
        // The plan lookup uses the rotated token, not the one that already came back 401.
        Assert.True(BearerIs(http.Requests[3], "tok-new"));
    }

    [Fact]
    public async Task SaveMergesWithoutDroppingOtherEntries()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] = """
            {"a::client-a":{"key":"tok-a","refresh_token":"refresh-a","expires_at":"2026-09-02T12:01:00Z","oidc_client_id":"oidc-a"},
             "b::client-b":{"key":"tok-b","expires_at":"2026-12-01T00:00:00Z","nickname":"work"}}
            """;
        var http = new FakeHttp()
            .On(GrokUsageClient.RefreshUrl, 200, """{"access_token":"tok-a2","expires_in":3600}""")
            .On(GrokUsageClient.BillingUrl, 200, Billing)
            .On(GrokUsageClient.SettingsUrl, 200, "{}");
        var provider = Provider(files, environment, http, new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        // `oidc_client_id` wins over the entry key's trailing segment.
        Assert.Contains("client_id=oidc-a", BodyText(http.Requests[0]), StringComparison.Ordinal);

        using var saved = JsonDocument.Parse(files.Files[AuthPath(environment)]);
        Assert.Equal("tok-a2", saved.RootElement.GetProperty("a::client-a").GetProperty("key").GetString());
        Assert.Equal("oidc-a", saved.RootElement.GetProperty("a::client-a").GetProperty("oidc_client_id").GetString());
        var untouched = saved.RootElement.GetProperty("b::client-b");
        Assert.Equal("tok-b", untouched.GetProperty("key").GetString());
        Assert.Equal("work", untouched.GetProperty("nickname").GetString());
    }

    [Fact]
    public async Task ExpiredCandidateWithoutRefreshTokenReportsExpired()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] =
            """{"acct":{"key":"tok-old","expires_at":"2026-09-01T00:00:00Z"}}""";
        var provider = Provider(files, environment, new FakeHttp(), new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(GrokQuotaProvider.ExpiredMessage, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task ChangedBillingShapeIsReported()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] = """{"acct":{"key":"tok-live"}}""";
        var http = new FakeHttp().On(GrokUsageClient.BillingUrl, 200, """{"config":{"used":{"val":1}}}""");
        var provider = Provider(files, environment, http, new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(GrokQuotaProvider.InvalidResponseMessage, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task TransportFailureBecomesConnectionError()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[AuthPath(environment)] = """{"acct":{"key":"tok-live"}}""";
        var provider = Provider(files, environment, new FakeHttp(), new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ProviderErrorText.ConnectionFailed, snapshot.ErrorMessage);
    }
}
