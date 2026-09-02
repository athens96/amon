using AMon.Quotas;
using AMon.Quotas.Providers.ZAI;

namespace AMon.Quotas.Tests;

public sealed class ZaiQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    private const long ResetEpochMs = 1770648402389;

    private const string Quota = """
        {"success":true,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":42.5,"nextResetTime":1770648402389},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":10},
          {"name":"TIME_LIMIT","unit":5,"number":1,"currentValue":12,"usage":100}
        ]}}
        """;

    private static string PrimaryConfigPath(FakeEnvironment environment) =>
        Path.Combine(environment.HomeDirectory, ".config", "openusage", "zai.json");

    private static ZaiQuotaProvider Provider(FakeFileSystem files, FakeEnvironment environment, FakeHttp http) =>
        new(new ZaiAuthStore(files, environment), new ZaiUsageClient(http), new FixedQuotaClock(Now));

    private static FakeEnvironment WithKey(string value = "zai-key")
    {
        var environment = new FakeEnvironment();
        environment.Variables["ZAI_API_KEY"] = value;
        return environment;
    }

    [Fact]
    public async Task MapsSessionWeeklyAndWebSearchMeters()
    {
        var environment = WithKey();
        var http = new FakeHttp()
            .On(ZaiUsageClient.QuotaUrl, 200, Quota)
            .On(ZaiUsageClient.SubscriptionUrl, 200, """{"data":[{"productName":"GLM Coding Max"}]}""");
        var provider = Provider(new FakeFileSystem(), environment, http);

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("GLM Coding Max", snapshot.Plan);
        Assert.Equal(3, snapshot.Lines.Count);

        var session = Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]);
        Assert.Equal("Session", session.Label);
        Assert.Equal(42.5, session.Used);
        Assert.Equal(QuotaMetricKind.Percent, session.Kind);
        Assert.Equal(QuotaPeriod.SessionMs, session.PeriodMilliseconds);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(ResetEpochMs), session.ResetsAt);

        var weekly = Assert.IsType<QuotaProgressLine>(snapshot.Lines[1]);
        Assert.Equal("Weekly", weekly.Label);
        Assert.Equal(10, weekly.Used);
        Assert.Equal(QuotaPeriod.WeekMs, weekly.PeriodMilliseconds);
        Assert.Null(weekly.ResetsAt);

        var searches = Assert.IsType<QuotaProgressLine>(snapshot.Lines[2]);
        Assert.Equal("Web Searches", searches.Label);
        Assert.Equal(12, searches.Used);
        Assert.Equal(100, searches.Limit);
        Assert.Equal(QuotaMetricKind.Count, searches.Kind);
        Assert.Equal("searches", searches.CountSuffix);
        Assert.Equal(QuotaPeriod.MonthMs, searches.PeriodMilliseconds);
        Assert.Equal("Bearer zai-key", http.Requests[0].Headers!["Authorization"]);
    }

    [Fact]
    public async Task MissingKeyIsNotDetected()
    {
        var provider = Provider(new FakeFileSystem(), new FakeEnvironment(), new FakeHttp());

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ZaiQuotaProvider.MissingKeyMessage, snapshot.ErrorMessage);
        Assert.Empty(snapshot.Lines);
    }

    [Fact]
    public async Task SuccessFalseCodingPlanBecomesNoPlanError()
    {
        var http = new FakeHttp().On(
            ZaiUsageClient.QuotaUrl,
            200,
            """{"success":false,"code":500,"msg":"No active coding plan for this account"}""");
        var provider = Provider(new FakeFileSystem(), WithKey(), http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ZaiQuotaProvider.NoCodingPlanMessage, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task UnrelatedBusinessFailureIsNotTreatedAsNoCodingPlan()
    {
        var http = new FakeHttp()
            .On(ZaiUsageClient.QuotaUrl, 200, """{"success":false,"code":500,"msg":"internal error"}""")
            .On(ZaiUsageClient.SubscriptionUrl, 500, "");
        var provider = Provider(new FakeFileSystem(), WithKey(), http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        var badge = Assert.IsType<QuotaBadgeLine>(Assert.Single(snapshot.Lines));
        Assert.Equal("Status", badge.Label);
        Assert.Equal("No usage data", badge.Text);
    }

    [Fact]
    public async Task EmptyLimitsBecomeTheNoUsageDataBadge()
    {
        var http = new FakeHttp()
            .On(ZaiUsageClient.QuotaUrl, 200, """{"success":true,"data":{"limits":[]}}""")
            .On(ZaiUsageClient.SubscriptionUrl, 200, """{"data":[]}""");
        var provider = Provider(new FakeFileSystem(), WithKey(), http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Null(snapshot.Plan);
        Assert.Equal("No usage data", Assert.IsType<QuotaBadgeLine>(Assert.Single(snapshot.Lines)).Text);
    }

    [Fact]
    public async Task UnauthorizedQuotaIsAnInvalidKey()
    {
        var http = new FakeHttp().On(ZaiUsageClient.QuotaUrl, 401, "");
        var provider = Provider(new FakeFileSystem(), WithKey(), http);

        Assert.Equal(
            ZaiQuotaProvider.InvalidKeyMessage,
            (await provider.RefreshAsync(CancellationToken.None)).ErrorMessage);
    }

    [Fact]
    public async Task SubscriptionFailureKeepsTheMeters()
    {
        var http = new FakeHttp()
            .On(ZaiUsageClient.QuotaUrl, 200, Quota)
            .On(ZaiUsageClient.SubscriptionUrl, 403, "");
        var provider = Provider(new FakeFileSystem(), WithKey(), http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Null(snapshot.Plan);
        Assert.Equal(3, snapshot.Lines.Count);
    }

    [Fact]
    public async Task TransportFailureBecomesConnectionError()
    {
        var provider = Provider(new FakeFileSystem(), WithKey(), new FakeHttp());

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ProviderErrorText.ConnectionFailed, snapshot.ErrorMessage);
    }

    [Fact]
    public void ConfigFileWinsOverEnvironmentAndLegacyName()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        environment.Variables["GLM_API_KEY"] = "glm-legacy";
        var store = new ZaiAuthStore(files, environment);

        Assert.Equal("glm-legacy", store.LoadApiKey()?.ApiKey);

        files.Files[PrimaryConfigPath(environment)] = """{"key":"zai-file"}""";
        var auth = store.LoadApiKey();
        Assert.Equal("zai-file", auth?.ApiKey);
        Assert.Equal(ZaiKeySource.ConfigFile, auth?.Source);
    }

    [Fact]
    public void TolerateLimitsAtTheRootAndSkipUnknownUnits()
    {
        var lines = ZaiUsageMapper.MapQuota("""
            {"limits":[
              {"type":"TOKENS_LIMIT","unit":9,"number":1,"percentage":50},
              {"type":"TOKENS_LIMIT","unit":4,"number":1,"percentage":250}
            ]}
            """);

        var weekly = Assert.IsType<QuotaProgressLine>(Assert.Single(lines));
        Assert.Equal("Weekly", weekly.Label);
        // A day-long window is not sub-daily, so it maps to the weekly meter; percentages clamp.
        Assert.Equal(100, weekly.Used);
    }
}
