using AMon.Quotas;
using AMon.Quotas.Providers.OpenRouter;

namespace AMon.Quotas.Tests;

public sealed class OpenRouterQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    private const string Credits = """{"data":{"total_usage":4.5,"total_credits":20}}""";

    private const string Key = """
        {"data":{"usage_daily":1.5,"usage_weekly":3,"usage_monthly":4.5,"limit":10,"usage":4.5,"is_free_tier":false}}
        """;

    private static string PrimaryConfigPath(FakeEnvironment environment) =>
        Path.Combine(environment.HomeDirectory, ".config", "openusage", "openrouter.json");

    private static OpenRouterQuotaProvider Provider(FakeFileSystem files, FakeEnvironment environment, FakeHttp http) =>
        new(new OpenRouterAuthStore(files, environment), new OpenRouterUsageClient(http), new FixedQuotaClock(Now));

    [Fact]
    public async Task MapsCreditsAndKeyMetrics()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[PrimaryConfigPath(environment)] = """{"apiKey":"sk-or-test"}""";
        var http = new FakeHttp()
            .On(OpenRouterUsageClient.CreditsUrl, 200, Credits)
            .On(OpenRouterUsageClient.KeyUrl, 200, Key);
        var provider = Provider(files, environment, http);

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("Pay as you go", snapshot.Plan);
        Assert.Equal(6, snapshot.Lines.Count);

        var credits = Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]);
        Assert.Equal("Credits", credits.Label);
        Assert.Equal(4.5, credits.Used);
        Assert.Equal(20, credits.Limit);
        Assert.Equal(QuotaMetricKind.Dollars, credits.Kind);

        var balance = Assert.IsType<QuotaValuesLine>(snapshot.Lines[1]);
        Assert.Equal("Balance", balance.Label);
        Assert.Equal(15.5, balance.Values.Single().Number);

        Assert.Equal(
            new[] { "Today", "This Week", "This Month" },
            snapshot.Lines.Skip(2).Take(3).Select(line => line.Label).ToArray());
        Assert.Equal(1.5, Assert.IsType<QuotaValuesLine>(snapshot.Lines[2]).Values.Single().Number);

        var keyLimit = Assert.IsType<QuotaProgressLine>(snapshot.Lines[5]);
        Assert.Equal("Key Limit", keyLimit.Label);
        Assert.Equal(10, keyLimit.Limit);
        Assert.Equal("Bearer sk-or-test", http.Requests[0].Headers!["Authorization"]);
    }

    [Fact]
    public async Task MissingKeyIsNotDetected()
    {
        var provider = Provider(new FakeFileSystem(), new FakeEnvironment(), new FakeHttp());

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(OpenRouterQuotaProvider.MissingKeyMessage, snapshot.ErrorMessage);
        Assert.Empty(snapshot.Lines);
    }

    [Fact]
    public async Task ForbiddenCreditsKeepsKeyLines()
    {
        var environment = new FakeEnvironment();
        environment.Variables["OPENROUTER_API_KEY"] = "sk-or-env";
        var http = new FakeHttp()
            .On(OpenRouterUsageClient.CreditsUrl, 403, "")
            .On(OpenRouterUsageClient.KeyUrl, 200, Key);
        var provider = Provider(new FakeFileSystem(), environment, http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal(4, snapshot.Lines.Count);
        Assert.Equal("Today", snapshot.Lines[0].Label);
    }

    [Fact]
    public async Task BothEndpointsForbiddenIsAnInvalidKey()
    {
        var environment = new FakeEnvironment();
        environment.Variables["OPENROUTER_KEY"] = "sk-or-env";
        var http = new FakeHttp()
            .On(OpenRouterUsageClient.CreditsUrl, 403, "")
            .On(OpenRouterUsageClient.KeyUrl, 401, "");
        var provider = Provider(new FakeFileSystem(), environment, http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(OpenRouterQuotaProvider.InvalidKeyMessage, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task TransportFailureBecomesConnectionError()
    {
        var environment = new FakeEnvironment();
        environment.Variables["OPENROUTER_API_KEY"] = "sk-or-env";
        var provider = Provider(new FakeFileSystem(), environment, new FakeHttp());

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ProviderErrorText.ConnectionFailed, snapshot.ErrorMessage);
    }

    [Fact]
    public void ConfigFileWinsOverEnvironment()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        environment.Variables["OPENROUTER_API_KEY"] = "sk-or-env";
        files.Files[PrimaryConfigPath(environment)] = """{"api_key":"sk-or-file"}""";
        var store = new OpenRouterAuthStore(files, environment);

        var auth = store.LoadApiKey();

        Assert.NotNull(auth);
        Assert.Equal("sk-or-file", auth!.ApiKey);
        Assert.Equal(OpenRouterKeySource.ConfigFile, auth.Source);
    }

    [Fact]
    public void ReadsPlainTextAndRoamingConfigFiles()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[Path.Combine(environment.ApplicationData, "openrouter", "key.json")] = "  sk-or-plain\n";
        var store = new OpenRouterAuthStore(files, environment);

        var auth = store.LoadApiKey();

        Assert.Equal("sk-or-plain", auth?.ApiKey);
        Assert.Null(OpenRouterAuthStore.KeyFromConfigText("""{"unrelated":"value"}"""));
        Assert.Null(OpenRouterAuthStore.KeyFromConfigText("   "));
        Assert.Equal("sk-or-nested", OpenRouterAuthStore.KeyFromConfigText("""{"key":"sk-or-nested"}"""));
    }

    [Fact]
    public async Task FreeTierAccountWithoutCreditsStillShowsBalance()
    {
        var environment = new FakeEnvironment();
        environment.Variables["OPENROUTER_API_KEY"] = "sk-or-env";
        var http = new FakeHttp()
            .On(OpenRouterUsageClient.CreditsUrl, 200, """{"data":{"total_usage":0.25,"total_credits":0}}""")
            .On(OpenRouterUsageClient.KeyUrl, 200, """{"data":{"is_free_tier":true,"limit":0}}""");
        var provider = Provider(new FakeFileSystem(), environment, http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal("Free tier", snapshot.Plan);
        var balance = Assert.IsType<QuotaValuesLine>(Assert.Single(snapshot.Lines));
        Assert.Equal("Balance", balance.Label);
        Assert.Equal(0, balance.Values.Single().Number);
    }
}
