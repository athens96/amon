using System.Text;
using AMon.Quotas.Providers.Antigravity;

namespace AMon.Quotas.Tests;

public sealed class AntigravityQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    /// One group with: a full pool, a partial pool, an unrecognized bucket id, a bucket with no
    /// `remainingFraction`, and an exhausted pool.
    private const string SummaryJson =
        """
        {"response":{"groups":[{"buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.4,"resetTime":"2026-09-02T15:00:00Z"},
          {"bucketId":"gemini-weekly","remainingFraction":0.75},
          {"bucketId":"gemini-image-5h","remainingFraction":0.1},
          {"bucketId":"3p-5h"},
          {"bucketId":"3p-weekly","remainingFraction":0}
        ]}]}}
        """;

    // MARK: - Credential extraction

    [Fact]
    public void ExtractsTheNestedAgyTokenObject()
    {
        var token = AntigravityAuthStore.ExtractToken(
            """{"token":{"access_token":"acc","refresh_token":"ref","expiry":"2026-09-02T13:00:00Z"}}""");

        Assert.NotNull(token);
        Assert.Equal("acc", token.AccessToken);
        Assert.Equal("ref", token.RefreshToken);
        Assert.Equal(new DateTimeOffset(2026, 9, 2, 13, 0, 0, TimeSpan.Zero), token.Expiry);
    }

    [Fact]
    public void ExtractsATokenThroughTheGoKeyringWrapper()
    {
        var json = """{"access_token":"wrapped"}""";
        var raw = "go-keyring-base64:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(json));

        Assert.Equal("wrapped", AntigravityAuthStore.ExtractToken(raw)?.AccessToken);
    }

    [Theory]
    [InlineData("\"bare\"", "bare")]
    [InlineData("Bearer prefixed", "prefixed")]
    [InlineData("raw-token", "raw-token")]
    [InlineData("""{"oauth":{"access_token":"nested"}}""", "nested")]
    [InlineData("""{"credentials":{"tokens":{"accessToken":"deep"}}}""", "deep")]
    public void ExtractsTheAccessTokenFromEveryStoredShape(string raw, string expected) =>
        Assert.Equal(expected, AntigravityAuthStore.ExtractToken(raw)?.AccessToken);

    [Fact]
    public void ExtractsNothingFromAnObjectWithoutTokens() =>
        Assert.Null(AntigravityAuthStore.ExtractToken("""{"unrelated":true}"""));

    // MARK: - Quota summary mapping

    [Fact]
    public void MapsTheQuotaSummaryEnvelopeSkippingUnusableBuckets()
    {
        var lines = AntigravityUsageMapper.ParseQuotaSummary(SummaryJson);

        Assert.NotNull(lines);
        Assert.Equal(3, lines.Count);
        var session = Assert.IsType<QuotaProgressLine>(lines[0]);
        Assert.Equal(AntigravityMetric.SessionLabel, session.Label);
        Assert.Equal(60, session.Used);
        Assert.Equal(QuotaPeriod.SessionMs, session.PeriodMilliseconds);
        Assert.Equal(new DateTimeOffset(2026, 9, 2, 15, 0, 0, TimeSpan.Zero), session.ResetsAt);

        var weekly = Assert.IsType<QuotaProgressLine>(lines[1]);
        Assert.Equal(AntigravityMetric.WeeklyLabel, weekly.Label);
        Assert.Equal(25, weekly.Used);
        Assert.Equal(QuotaPeriod.WeekMs, weekly.PeriodMilliseconds);

        // `3p-5h` had no remainingFraction, so its line is dropped rather than fabricated.
        var claudeWeekly = Assert.IsType<QuotaProgressLine>(lines[2]);
        Assert.Equal(AntigravityMetric.ClaudeWeeklyLabel, claudeWeekly.Label);
        Assert.Equal(100, claudeWeekly.Used);
    }

    [Fact]
    public void MapsTheBareRemoteSummaryEnvelope()
    {
        var lines = AntigravityUsageMapper.ParseQuotaSummary(
            """{"groups":[{"buckets":[{"bucketId":"3p-5h","remainingFraction":0.5}]}]}""");

        var claude = Assert.IsType<QuotaProgressLine>(Assert.Single(lines!));
        Assert.Equal(AntigravityMetric.ClaudeLabel, claude.Label);
        Assert.Equal(50, claude.Used);
    }

    [Fact]
    public void AnEmptySummaryIsStillAuthoritativeButANonSummaryIsNot()
    {
        Assert.Empty(AntigravityUsageMapper.ParseQuotaSummary("""{"groups":[]}""")!);
        Assert.Null(AntigravityUsageMapper.ParseQuotaSummary("""{"models":{}}"""));
        Assert.Null(AntigravityUsageMapper.ParseQuotaSummary("not json"));
    }

    // MARK: - Legacy pooling

    [Fact]
    public void PoolsLegacyModelsIntoSessionAndClaudeKeepingTheWorstFraction()
    {
        const string models =
            """
            {"models":{
              "gemini-3-pro":{"displayName":"Gemini 3 Pro (High)","model":"MODEL_GEMINI_3_PRO","quotaInfo":{"remainingFraction":0.5}},
              "gemini-3-flash":{"displayName":"Gemini 3 Flash","model":"MODEL_GEMINI_3_FLASH","quotaInfo":{"remainingFraction":0.2}},
              "claude":{"displayName":"Claude Sonnet 4.5","model":"MODEL_CLAUDE","quotaInfo":{"remainingFraction":0.9}},
              "old-gemini":{"displayName":"Gemini 2.5 Pro","model":"MODEL_GOOGLE_GEMINI_2_5_PRO","quotaInfo":{"remainingFraction":0.01}},
              "hidden":{"displayName":"Internal","model":"MODEL_INTERNAL","isInternal":true,"quotaInfo":{"remainingFraction":0}}
            }}
            """;

        var lines = AntigravityUsageMapper.BuildLines(AntigravityUsageMapper.ParseCloudCodeModels(models));

        Assert.Equal(2, lines.Count);
        var session = Assert.IsType<QuotaProgressLine>(lines[0]);
        Assert.Equal(AntigravityMetric.SessionLabel, session.Label);
        Assert.Equal(80, session.Used); // worst Gemini fraction (0.2); the blacklisted 0.01 is dropped
        Assert.Equal(QuotaPeriod.SessionMs, session.PeriodMilliseconds);
        var claude = Assert.IsType<QuotaProgressLine>(lines[1]);
        Assert.Equal(AntigravityMetric.ClaudeLabel, claude.Label);
        Assert.Equal(10, claude.Used);
    }

    [Fact]
    public void ParsesUserStatusPlanAndConfigs()
    {
        var status = AntigravityUsageMapper.ParseUserStatus(
            """
            {"userStatus":{"userTier":{"name":"Google AI Ultra"},"planStatus":{"planInfo":{"planName":"Pro"}},
             "cascadeModelConfigData":{"clientModelConfigs":[
               {"label":"Gemini 3 Pro","modelOrAlias":{"model":"MODEL_GEMINI_3_PRO"},"quotaInfo":{"remainingFraction":0.25}}]}}}
            """);

        Assert.NotNull(status);
        Assert.Equal("Ultra", status.Plan);
        var config = Assert.Single(status.Configs);
        Assert.Equal("Gemini 3 Pro", config.Label);
        Assert.Equal(0.25, config.RemainingFraction);
        Assert.Null(AntigravityUsageMapper.ParseUserStatus("""{"other":1}"""));
    }

    [Theory]
    [InlineData("Google AI Pro", "Pro")]
    [InlineData("Gemini Code Assist in Google One AI Ultra", "Ultra")]
    [InlineData("free tier", "Free")]
    [InlineData("windsurf teams", "Windsurf Teams")]
    [InlineData("   ", null)]
    [InlineData(null, null)]
    public void FormatsPlanNames(string? raw, string? expected) =>
        Assert.Equal(expected, AntigravityUsageMapper.FormatPlan(raw));

    // MARK: - Language-server path

    [Fact]
    public async Task ReadsTheQuotaSummaryFromADiscoveredLanguageServer()
    {
        const string command =
            """"
            "C:\Users\t\AppData\Local\Programs\Antigravity\bin\language_server_windows_x64.exe" --csrf_token abc --extension_server_port 4321 --app_data_dir antigravity
            """";
        var runner = new FakeProcessRunner();
        runner.Results["powershell.exe"] = new ProcessRunResult(0, $"1234 {command}\n");
        runner.Results["netstat.exe"] = new ProcessRunResult(
            0,
            "  TCP    127.0.0.1:52168        0.0.0.0:0              LISTENING       1234\n");
        var http = new FakeHttp()
            .On("https://127.0.0.1:52168/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary", 200, SummaryJson)
            .On(
                "https://127.0.0.1:52168/exa.language_server_pb.LanguageServerService/GetUserStatus",
                200,
                """{"userStatus":{"userTier":{"name":"Google AI Ultra"}}}""");
        var provider = Build(new FakeCredentialStore(), new FakeFileSystem(), new FakeEnvironment(), http, runner);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("Ultra", snapshot.Plan);
        Assert.Equal(3, snapshot.Lines.Count);
        Assert.Equal("abc", http.Requests[0].Headers!["x-codeium-csrf-token"]);
        Assert.Equal("1", http.Requests[0].Headers!["Connect-Protocol-Version"]);
    }

    // MARK: - Cloud Code path

    [Fact]
    public async Task RefreshesTheStoredTokenAfterA401AndRetries()
    {
        var credentials = new FakeCredentialStore();
        credentials.Credentials[AntigravityAuthStore.CredentialTarget] =
            """{"token":{"access_token":"old","refresh_token":"ref"}}""";
        var environment = new FakeEnvironment();
        environment.Variables[AntigravityUsageClient.ClientIdVariable] = "client";
        environment.Variables[AntigravityUsageClient.ClientSecretVariable] = "secret";
        var files = new FakeFileSystem();
        var http = new FakeHttp()
            .On(
                request => request.Url.Contains(AntigravityUsageClient.QuotaSummaryPath, StringComparison.Ordinal)
                    && Authorization(request) == "Bearer old",
                _ => FakeHttp.Response(401, "{}"))
            .On(
                request => request.Url.Contains(AntigravityUsageClient.QuotaSummaryPath, StringComparison.Ordinal)
                    && Authorization(request) == "Bearer fresh",
                _ => FakeHttp.Response(200, SummaryJson))
            .On(AntigravityUsageClient.GoogleOAuthUrl, 200, """{"access_token":"fresh","expires_in":3600}""")
            .On(AntigravityUsageClient.LoadCodeAssistPath, 200, """{"currentTier":{"name":"Google AI Pro"}}""");
        var provider = Build(credentials, files, environment, http, new FakeProcessRunner());

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("Pro", snapshot.Plan);
        Assert.Equal(3, snapshot.Lines.Count);
        Assert.Contains("grant_type=refresh_token", Encoding.UTF8.GetString(
            http.Requests.Single(request => request.Url == AntigravityUsageClient.GoogleOAuthUrl).Body!),
            StringComparison.Ordinal);
        // The refreshed token is cached for the next cycle, never written back to Credential Manager.
        Assert.Contains("fresh", files.Files[Path.Combine(environment.ApplicationData, "A-mon", "quota-cache", "antigravity-auth.json")], StringComparison.Ordinal);
    }

    [Fact]
    public async Task ReportsATransientOutageWhenTheOAuthCredentialsAreMissing()
    {
        var credentials = new FakeCredentialStore();
        credentials.Credentials[AntigravityAuthStore.CredentialTarget] =
            """{"token":{"access_token":"old","refresh_token":"ref"}}""";
        var http = new FakeHttp().On(
            request => request.Url.StartsWith("https://daily-cloudcode-pa", StringComparison.Ordinal)
                || request.Url.StartsWith("https://cloudcode-pa", StringComparison.Ordinal),
            _ => FakeHttp.Response(401, "{}"));
        var provider = Build(credentials, new FakeFileSystem(), new FakeEnvironment(), http, new FakeProcessRunner());

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(AntigravityQuotaProvider.UnavailableMessage, snapshot.ErrorMessage);
        Assert.DoesNotContain(http.Requests, request => request.Url == AntigravityUsageClient.GoogleOAuthUrl);
    }

    [Fact]
    public async Task ReportsExpiredAuthWhenARejectedTokenCannotBeRefreshed()
    {
        var credentials = new FakeCredentialStore();
        credentials.Credentials[AntigravityAuthStore.CredentialTarget] = """{"token":{"access_token":"old"}}""";
        var http = new FakeHttp().On(request => request.Url.Contains("googleapis.com", StringComparison.Ordinal), _ => FakeHttp.Response(403, "{}"));
        var provider = Build(credentials, new FakeFileSystem(), new FakeEnvironment(), http, new FakeProcessRunner());

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(AntigravityQuotaProvider.AuthExpiredMessage, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task ReportsNotSignedInWithoutAnyCredentials()
    {
        var provider = Build(new FakeCredentialStore(), new FakeFileSystem(), new FakeEnvironment(), new FakeHttp(), new FakeProcessRunner());

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);
        Assert.Equal(AntigravityQuotaProvider.NotSignedInMessage, snapshot.ErrorMessage);
        Assert.Empty(snapshot.Lines);
    }

    // MARK: - Local detection

    [Fact]
    public async Task DetectsCredentialsFromTheRefreshedTokenCacheAlone()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.ApplicationData, "A-mon", "quota-cache", "antigravity-auth.json")] =
            $$"""{"accessToken":"cached","expiresAtMs":{{Now.AddHours(1).ToUnixTimeMilliseconds()}}}""";
        var provider = Build(new FakeCredentialStore(), files, environment, new FakeHttp(), new FakeProcessRunner());

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
    }

    [Fact]
    public async Task IgnoresAnExpiredCachedToken()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.ApplicationData, "A-mon", "quota-cache", "antigravity-auth.json")] =
            $$"""{"accessToken":"cached","expiresAtMs":{{Now.AddSeconds(30).ToUnixTimeMilliseconds()}}}""";
        var provider = Build(new FakeCredentialStore(), files, environment, new FakeHttp(), new FakeProcessRunner());

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
    }

    private static string? Authorization(QuotaHttpRequest request) =>
        request.Headers is not null && request.Headers.TryGetValue("Authorization", out var value) ? value : null;

    private static AntigravityQuotaProvider Build(
        FakeCredentialStore credentials,
        FakeFileSystem files,
        FakeEnvironment environment,
        FakeHttp http,
        FakeProcessRunner runner)
    {
        var clock = new FixedQuotaClock(Now);
        return new AntigravityQuotaProvider(
            new AntigravityAuthStore(credentials, files, environment, clock),
            new AntigravityUsageClient(http, http, environment),
            new LanguageServerDiscovery(runner),
            clock);
    }
}
