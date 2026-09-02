using AMon.Quotas;
using AMon.Quotas.Providers.Codex;

namespace AMon.Quotas.Tests;

public sealed class CodexQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task MapsRateLimitWindowsAndSendsAccountId()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[Path.Combine(environment.HomeDirectory, ".codex", "auth.json")] =
            """{"tokens":{"access_token":"tok","account_id":"acc-1"}}""";
        var http = new FakeHttp().On(
            CodexUsageClient.UsageUrl,
            200,
            """{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":40,"reset_at":1756818000},"secondary_window":{"used_percent":5,"resets_at":1757250000}}}""");
        var provider = new CodexQuotaProvider(
            new CodexAuthStore(files, environment),
            new CodexUsageClient(http),
            new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal("Pro", snapshot.Plan);
        Assert.Equal(2, snapshot.Lines.Count);
        var session = Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]);
        Assert.Equal(40, session.Used);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1756818000), session.ResetsAt);
        var weekly = Assert.IsType<QuotaProgressLine>(snapshot.Lines[1]);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1757250000), weekly.ResetsAt);
        Assert.Equal("acc-1", http.Requests.Single().Headers!["ChatGPT-Account-Id"]);
    }

    [Fact]
    public async Task HonorsCodexHomeOverride()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        environment.Variables["CODEX_HOME"] = "/custom/codex";
        files.Files[Path.Combine("/custom/codex", "auth.json")] = """{"tokens":{"access_token":"tok"}}""";
        var provider = new CodexQuotaProvider(
            new CodexAuthStore(files, environment),
            new CodexUsageClient(new FakeHttp()),
            new FixedQuotaClock(Now));

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
    }

    [Fact]
    public async Task ApiKeyOnlyAuthFileIsNotDetected()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[Path.Combine(environment.HomeDirectory, ".codex", "auth.json")] = """{"OPENAI_API_KEY":"sk-…"}""";
        var provider = new CodexQuotaProvider(
            new CodexAuthStore(files, environment),
            new CodexUsageClient(new FakeHttp()),
            new FixedQuotaClock(Now));

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);
        Assert.Equal("Codex OAuth 토큰을 찾지 못했습니다.", snapshot.ErrorMessage);
    }
}
