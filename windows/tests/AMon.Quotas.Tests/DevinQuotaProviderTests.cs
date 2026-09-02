using System.Text;
using AMon.Quotas;
using AMon.Quotas.Providers.Devin;

namespace AMon.Quotas.Tests;

public sealed class DevinQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    private const string UserStatusBody = """
        {
          "userStatus": {
            "planStatus": {
              "planInfo": { "planName": "Devin Team", "hideDailyQuota": false },
              "dailyQuotaRemainingPercent": 75,
              "weeklyQuotaRemainingPercent": 40,
              "dailyQuotaResetAtUnix": 1788393600,
              "weeklyQuotaResetAtUnix": 1788652800,
              "overageBalanceMicros": 4080000
            }
          }
        }
        """;

    [Fact]
    public async Task MapsDailyWeeklyAndOverageBalance()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "devin", "credentials.toml")] =
            "windsurf_api_key = \"key-file\"\n";
        var http = new FakeHttp().On(DevinAuthStore.DefaultApiServerUrl, 200, UserStatusBody);
        var provider = Provider(files, environment, new FakeDevinStateReader(), http);

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("Devin Team", snapshot.Plan);
        Assert.Equal(3, snapshot.Lines.Count);

        var daily = Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]);
        Assert.Equal("Daily quota", daily.Label);
        Assert.Equal(25, daily.Used);
        Assert.Equal(QuotaPeriod.DayMs, daily.PeriodMilliseconds);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1788393600), daily.ResetsAt);

        var weekly = Assert.IsType<QuotaProgressLine>(snapshot.Lines[1]);
        Assert.Equal("Weekly quota", weekly.Label);
        Assert.Equal(60, weekly.Used);
        Assert.Equal(QuotaPeriod.WeekMs, weekly.PeriodMilliseconds);

        var balance = Assert.IsType<QuotaValuesLine>(snapshot.Lines[2]);
        Assert.Equal("Extra usage balance", balance.Label);
        Assert.Equal(4.08, Assert.Single(balance.Values).Number, 6);
        Assert.Equal(QuotaMetricKind.Dollars, balance.Values[0].Kind);

        var request = Assert.Single(http.Requests);
        Assert.Equal($"{DevinAuthStore.DefaultApiServerUrl}/{DevinUsageClient.CloudService}/GetUserStatus", request.Url);
        Assert.Equal("1", request.Headers!["Connect-Protocol-Version"]);
        Assert.Contains("\"apiKey\":\"key-file\"", Body(request), StringComparison.Ordinal);
    }

    [Fact]
    public async Task FallsBackToAppStateWhenTheCredentialsFileKeyIsRejected()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "devin", "credentials.toml")] =
            "windsurf_api_key = \"stale\"\n";
        var stateReader = new FakeDevinStateReader
        {
            AuthStatus = """{"apiKey":"fresh"}""",
        };
        var http = new FakeHttp()
            .On(request => Body(request).Contains("\"apiKey\":\"stale\"", StringComparison.Ordinal), _ => FakeHttp.Response(401, "{}"))
            .On(DevinAuthStore.DefaultApiServerUrl, 200, UserStatusBody);
        var provider = Provider(files, environment, stateReader, http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal(2, http.Requests.Count);
        Assert.Contains("\"apiKey\":\"fresh\"", Body(http.Requests[1]), StringComparison.Ordinal);
        Assert.Equal(environment.AppData("Devin", "User", "globalStorage", "state.vscdb"), stateReader.RequestedPaths[0]);
    }

    [Fact]
    public async Task AppAuthIsSkippedWhenItRepeatsTheCredentialsFileKey()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "devin", "credentials.toml")] = "windsurf_api_key = \"same\"\n";
        var stateReader = new FakeDevinStateReader { AuthStatus = """{"apiKey":"same"}""" };
        var http = new FakeHttp().On(DevinAuthStore.DefaultApiServerUrl, 401, "{}");
        var provider = Provider(files, environment, stateReader, http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Single(http.Requests);
        Assert.Equal(DevinQuotaProvider.NotLoggedIn, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task NonAuthFailureReportsQuotaUnavailable()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "devin", "credentials.toml")] = "windsurf_api_key = \"key\"\n";
        var http = new FakeHttp().On(DevinAuthStore.DefaultApiServerUrl, 500, "boom");
        var provider = Provider(files, environment, new FakeDevinStateReader(), http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(DevinQuotaProvider.QuotaUnavailable, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task TransportFailureReportsQuotaUnavailable()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "devin", "credentials.toml")] = "windsurf_api_key = \"key\"\n";
        var provider = Provider(files, environment, new FakeDevinStateReader(), new FakeHttp());

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(DevinQuotaProvider.QuotaUnavailable, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task NoCredentialsAnywhereIsNotDetected()
    {
        var provider = Provider(new FakeFileSystem(), new FakeEnvironment(), new FakeDevinStateReader(), new FakeHttp());

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);
        Assert.Equal(DevinQuotaProvider.NotLoggedIn, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task CustomApiServerUrlFromTheCredentialsFileIsUsed()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.ApplicationData, "devin", "credentials.toml")] =
            "windsurf_api_key = \"key\"\napi_server_url = \"https://tenant.example.com///\"\n";
        var http = new FakeHttp().On("https://tenant.example.com/", 200, UserStatusBody);
        var provider = Provider(files, environment, new FakeDevinStateReader(), http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal(
            $"https://tenant.example.com/{DevinUsageClient.CloudService}/GetUserStatus",
            Assert.Single(http.Requests).Url);
    }

    [Theory]
    [InlineData("windsurf_api_key = \"quoted # not a comment\"\n", "quoted # not a comment")]
    [InlineData("windsurf_api_key = 'single'\n", "single")]
    [InlineData("windsurf_api_key = bare  # trailing comment\n", "bare")]
    [InlineData("windsurf_api_key=tight\n", "tight")]
    [InlineData("  windsurf_api_key = spaced \n", "spaced")]
    [InlineData("windsurf_api_key = \n", null)]
    [InlineData("windsurf_api_key = \"unterminated\n", null)]
    [InlineData("windsurf_api_key = # only a comment\n", null)]
    [InlineData("other_key = value\n", null)]
    public void ReadTomlStringHandlesQuotesAndComments(string toml, string? expected) =>
        Assert.Equal(expected, DevinAuthStore.ReadTomlString(toml, "windsurf_api_key"));

    [Theory]
    [InlineData("https://server.example.com/", "https://server.example.com")]
    [InlineData("  https://server.example.com  ", "https://server.example.com")]
    [InlineData("http://insecure.example.com", null)]
    [InlineData(null, null)]
    public void CleanApiServerUrlRequiresHttps(string? raw, string? expected) =>
        Assert.Equal(expected, DevinAuthStore.CleanApiServerUrl(raw));

    [Fact]
    public void HiddenDailyQuotaFallsBackIntoTheWeeklyRow()
    {
        using var document = QuotaJson.ParseObject(
            """
            {
              "userStatus": {
                "planStatus": {
                  "planInfo": { "hideDailyQuota": true },
                  "dailyQuotaRemainingPercent": 10,
                  "weeklyQuotaResetAtUnix": 1788652800
                }
              }
            }
            """)!;

        var mapped = DevinUsageMapper.MapUserStatusResponse(document.RootElement)!;

        Assert.Equal("Unknown", mapped.Plan);
        var weekly = Assert.IsType<QuotaProgressLine>(Assert.Single(mapped.Lines));
        Assert.Equal("Weekly quota", weekly.Label);
        Assert.Equal(90, weekly.Used);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1788652800), weekly.ResetsAt);
    }

    [Fact]
    public void AZeroOverageBalanceIsStillAMeasuredValue()
    {
        using var document = QuotaJson.ParseObject(
            """{"userStatus":{"planStatus":{"overageBalanceMicros":0}}}""")!;

        var mapped = DevinUsageMapper.MapUserStatusResponse(document.RootElement)!;

        var balance = Assert.IsType<QuotaValuesLine>(Assert.Single(mapped.Lines));
        Assert.Equal(0, Assert.Single(balance.Values).Number);
    }

    [Fact]
    public void AnEmptyStatusMapsToNothing()
    {
        using var document = QuotaJson.ParseObject("""{"userStatus":{"planStatus":{}}}""")!;

        Assert.Null(DevinUsageMapper.MapUserStatusResponse(document.RootElement));
    }

    private static string Body(QuotaHttpRequest request) =>
        request.Body is null ? string.Empty : Encoding.UTF8.GetString(request.Body);

    private static DevinQuotaProvider Provider(
        FakeFileSystem files,
        FakeEnvironment environment,
        IDevinStateReader stateReader,
        FakeHttp http) =>
        new(new DevinAuthStore(files, environment, stateReader), new DevinUsageClient(http), new FixedQuotaClock(Now));

    private sealed class FakeDevinStateReader : IDevinStateReader
    {
        public string? AuthStatus { get; set; }

        public List<string> RequestedPaths { get; } = [];

        public string? ReadAuthStatus(string databasePath)
        {
            RequestedPaths.Add(databasePath);
            return AuthStatus;
        }
    }
}
