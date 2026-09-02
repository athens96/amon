using AMon.Quotas;
using AMon.Quotas.Providers.Copilot;

namespace AMon.Quotas.Tests;

public sealed class CopilotQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    /// A paid seat: metered Credits, overage enabled, chat/completions on the `-1` unlimited sentinel.
    private const string PaidBody = """
        {
          "copilot_plan": "copilot_pro_plus",
          "quota_reset_date": "2026-10-01T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 1500,
              "remaining": 900,
              "percent_remaining": 60,
              "unlimited": false,
              "overage_permitted": true,
              "overage_count": 12
            },
            "chat": { "entitlement": -1, "remaining": -1, "unlimited": true },
            "completions": { "entitlement": -1, "remaining": -1, "unlimited": true }
          }
        }
        """;

    [Fact]
    public async Task MapsCreditsAndOverageFromEditorConfigToken()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "github-copilot", "apps.json")] =
            """{"github.com:Iv23aaa":{"oauth_token":"gho_new"},"github.com:01ab":{"oauth_token":"gho_old"}}""";
        var http = new FakeHttp().On(CopilotUsageClient.UsageUrl, 200, PaidBody);
        var provider = Provider(files, environment, new FakeCredentialStore(), http);

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("Copilot Pro Plus", snapshot.Plan);
        Assert.Equal(2, snapshot.Lines.Count);
        var credits = Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]);
        Assert.Equal("Credits", credits.Label);
        Assert.Equal(40, credits.Used);
        Assert.Equal(QuotaMetricKind.Percent, credits.Kind);
        Assert.Equal(QuotaPeriod.MonthMs, credits.PeriodMilliseconds);
        Assert.Equal(new DateTimeOffset(2026, 10, 1, 0, 0, 0, TimeSpan.Zero), credits.ResetsAt);
        var extra = Assert.IsType<QuotaValuesLine>(snapshot.Lines[1]);
        Assert.Equal("Extra Usage", extra.Label);
        Assert.Equal(12, Assert.Single(extra.Values).Number);
        Assert.Equal(QuotaMetricKind.Count, extra.Values[0].Kind);
        // Descending key order puts the newer `Iv23…` app entry first.
        Assert.Equal("token gho_new", Assert.Single(http.Requests).Headers!["Authorization"]);
    }

    [Fact]
    public async Task FallsThroughToTheNextCandidateOnAuthFailure()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "github-copilot", "apps.json")] =
            """{"github.com:Iv23aaa":{"oauth_token":"expired"}}""";
        files.Files[Path.Combine(environment.ApplicationData, "GitHub CLI", "hosts.yml")] =
            "github.com:\n    user: octocat\n    oauth_token: gho_gh\n";
        var http = new FakeHttp()
            .On(request => request.Headers!["Authorization"] == "token expired", _ => FakeHttp.Response(401, "{}"))
            .On(CopilotUsageClient.UsageUrl, 200, PaidBody);
        var provider = Provider(files, environment, new FakeCredentialStore(), http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal(2, http.Requests.Count);
        Assert.Equal("token gho_gh", http.Requests[1].Headers!["Authorization"]);
    }

    [Fact]
    public async Task AllCandidatesUnauthorizedReportsExpiredToken()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "github-copilot", "apps.json")] =
            """{"github.com":{"oauth_token":"expired"}}""";
        var http = new FakeHttp().On(CopilotUsageClient.UsageUrl, 403, "{}");
        var provider = Provider(files, environment, new FakeCredentialStore(), http);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(CopilotQuotaProvider.TokenInvalid, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task TokenBasedBillingSeatIsAnEmptySuccess()
    {
        var http = new FakeHttp().On(
            CopilotUsageClient.UsageUrl,
            200,
            """{"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0}}}""");
        var provider = ProviderWithToken(http, out _);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("Business", snapshot.Plan);
        Assert.Empty(snapshot.Lines);
    }

    [Fact]
    public async Task SubscriptionEndedIsItsOwnFailure()
    {
        var http = new FakeHttp().On(
            CopilotUsageClient.UsageUrl,
            200,
            """{"copilot_plan":"copilot_pro","access_type_sku":"subscription_ended"}""");
        var provider = ProviderWithToken(http, out _);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(CopilotUsageMapper.SubscriptionEnded, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task EmptyPayloadWithoutMarkersIsUnavailable()
    {
        var http = new FakeHttp().On(CopilotUsageClient.UsageUrl, 200, """{"copilot_plan":"copilot_pro"}""");
        var provider = ProviderWithToken(http, out _);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(CopilotUsageMapper.QuotaUnavailable, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task NonAuthFailureStatusStopsTheCandidateLoop()
    {
        var http = new FakeHttp().On(CopilotUsageClient.UsageUrl, 500, "boom");
        var provider = ProviderWithToken(http, out _);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ProviderErrorText.RequestFailed(500), snapshot.ErrorMessage);
    }

    [Fact]
    public async Task NoCredentialsAnywhereIsNotDetected()
    {
        var provider = Provider(new FakeFileSystem(), new FakeEnvironment(), new FakeCredentialStore(), new FakeHttp());

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);
        Assert.Equal(CopilotQuotaProvider.NotLoggedIn, snapshot.ErrorMessage);
    }

    [Fact]
    public async Task TransportFailureBecomesConnectionError()
    {
        var provider = ProviderWithToken(new FakeHttp(), out _);

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ProviderErrorText.ConnectionFailed, snapshot.ErrorMessage);
    }

    [Fact]
    public void LegacyFreeTierQuotasMapWhenNothingElseIsProduced()
    {
        using var document = QuotaJson.ParseObject(
            """
            {
              "copilot_plan": "free",
              "limited_user_reset_date": "2026-09-30",
              "limited_user_quotas": { "chat": 20, "completions": 1000 },
              "monthly_quotas": { "chat": 50, "completions": 2000 }
            }
            """)!;

        var mapped = CopilotUsageMapper.Map(document.RootElement);

        Assert.False(mapped.IsError);
        Assert.Equal("Free", mapped.Plan);
        var chat = Assert.IsType<QuotaProgressLine>(mapped.Lines[0]);
        Assert.Equal("Chat", chat.Label);
        Assert.Equal(60, chat.Used);
        Assert.Equal(new DateTimeOffset(2026, 9, 30, 0, 0, 0, TimeSpan.Zero), chat.ResetsAt);
        var completions = Assert.IsType<QuotaProgressLine>(mapped.Lines[1]);
        Assert.Equal(50, completions.Used);
    }

    [Fact]
    public void ZeroEntitlementAndUnlimitedBucketsAreSuppressed()
    {
        using var document = QuotaJson.ParseObject(
            """
            {
              "quota_snapshots": {
                "premium_interactions": { "entitlement": 0, "remaining": 0 },
                "chat": { "entitlement": -1, "remaining": -1 },
                "completions": { "entitlement": 100, "remaining": 25 }
              }
            }
            """)!;

        var mapped = CopilotUsageMapper.Map(document.RootElement);

        var only = Assert.IsType<QuotaProgressLine>(Assert.Single(mapped.Lines));
        Assert.Equal("Completions", only.Label);
        Assert.Equal(75, only.Used);
    }

    [Theory]
    // Only the github.com block's keys are read: an Enterprise block must not leak its token.
    [InlineData("github.com:\n    user: octocat\n    oauth_token: gho_ok\nghe.example.com:\n    oauth_token: nope\n", "gho_ok")]
    [InlineData("ghe.example.com:\n    oauth_token: nope\ngithub.com:\n    oauth_token: \"gho_quoted\"\n", "gho_quoted")]
    [InlineData("ghe.example.com:\n    oauth_token: nope\n", null)]
    public void YamlValueIsScopedToTheGithubHostBlock(string yaml, string? expected) =>
        Assert.Equal(expected, CopilotAuthStore.YamlValue(yaml, "oauth_token"));

    [Fact]
    public void UserKeyDoesNotMatchTheNestedUsersMap() =>
        Assert.Equal("octocat", CopilotAuthStore.YamlValue("github.com:\n    users:\n        octocat:\n    user: octocat\n", "user"));

    [Fact]
    public void CredentialManagerTokenIsScopedToTheGhUserAndUnwrapped()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.ApplicationData, "GitHub CLI", "hosts.yml")] = "github.com:\n    user: octocat\n";
        var credentials = new FakeCredentialStore();
        credentials.Credentials[$"{CopilotAuthStore.GhCredentialService}:octocat"] =
            "go-keyring-base64:" + Convert.ToBase64String("gho_keyring"u8.ToArray());
        var store = new CopilotAuthStore(files, environment, credentials);

        var token = Assert.Single(store.LoadTokenCandidates());
        Assert.Equal("gho_keyring", token.Value);
        Assert.Equal(CopilotTokenSource.GhCredentialManager, token.Source);
    }

    [Fact]
    public void GhConfigDirOverridesTheDefaultHostsLocation()
    {
        var environment = new FakeEnvironment();
        environment.Variables["GH_CONFIG_DIR"] = "/custom/gh";
        var files = new FakeFileSystem();
        files.Files[Path.Combine("/custom/gh", "hosts.yml")] = "github.com:\n    oauth_token: gho_custom\n";
        files.Files[Path.Combine(environment.ApplicationData, "GitHub CLI", "hosts.yml")] = "github.com:\n    oauth_token: gho_default\n";
        var store = new CopilotAuthStore(files, environment, new FakeCredentialStore());

        Assert.Equal("gho_custom", store.LoadFromGhConfig()!.Value);
    }

    [Fact]
    public void EditorTokensAreDedupedAcrossConfigFiles()
    {
        var environment = new FakeEnvironment();
        var files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "github-copilot", "apps.json")] =
            """{"github.com:b":{"oauth_token":"dup"},"ghe.example.com:z":{"oauth_token":"enterprise"}}""";
        files.Files[Path.Combine(environment.HomeDirectory, ".config", "github-copilot", "hosts.json")] =
            """{"github.com":{"oauth_token":"dup"}}""";
        var store = new CopilotAuthStore(files, environment, new FakeCredentialStore());

        var token = Assert.Single(store.LoadTokenCandidates());
        Assert.Equal("dup", token.Value);
    }

    private static CopilotQuotaProvider Provider(
        FakeFileSystem files,
        FakeEnvironment environment,
        FakeCredentialStore credentials,
        FakeHttp http) =>
        new(new CopilotAuthStore(files, environment, credentials), new CopilotUsageClient(http), new FixedQuotaClock(Now));

    private static CopilotQuotaProvider ProviderWithToken(FakeHttp http, out FakeFileSystem files)
    {
        var environment = new FakeEnvironment();
        files = new FakeFileSystem();
        files.Files[Path.Combine(environment.LocalApplicationData, "github-copilot", "apps.json")] =
            """{"github.com":{"oauth_token":"gho_one"}}""";
        return Provider(files, environment, new FakeCredentialStore(), http);
    }
}
