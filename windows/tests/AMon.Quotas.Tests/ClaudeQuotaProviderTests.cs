using AMon.Quotas;
using AMon.Quotas.Providers.Claude;

namespace AMon.Quotas.Tests;

public sealed class ClaudeQuotaProviderTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 2, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task MapsUtilizationWindowsAndPlan()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[Path.Combine(environment.HomeDirectory, ".claude", ".credentials.json")] =
            """{"claudeAiOauth":{"accessToken":"tok","subscriptionType":"max"}}""";
        var http = new FakeHttp().On(
            ClaudeUsageClient.UsageUrl,
            200,
            """{"five_hour":{"utilization":37.5,"resets_at":"2026-09-02T14:00:00Z"},"seven_day":{"utilization":12}}""");
        var provider = new ClaudeQuotaProvider(
            new ClaudeAuthStore(files, environment),
            new ClaudeUsageClient(http),
            new FixedQuotaClock(Now));

        Assert.True(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.False(snapshot.IsError);
        Assert.Equal("Max", snapshot.Plan);
        Assert.Equal(2, snapshot.Lines.Count);
        var session = Assert.IsType<QuotaProgressLine>(snapshot.Lines[0]);
        Assert.Equal("Session", session.Label);
        Assert.Equal(37.5, session.Used);
        Assert.Equal(new DateTimeOffset(2026, 9, 2, 14, 0, 0, TimeSpan.Zero), session.ResetsAt);
        Assert.Equal("Bearer tok", http.Requests.Single().Headers!["Authorization"]);
    }

    [Fact]
    public async Task MissingCredentialsFileIsNotDetected()
    {
        var provider = new ClaudeQuotaProvider(
            new ClaudeAuthStore(new FakeFileSystem(), new FakeEnvironment()),
            new ClaudeUsageClient(new FakeHttp()),
            new FixedQuotaClock(Now));

        Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None));
        var snapshot = await provider.RefreshAsync(CancellationToken.None);
        Assert.True(snapshot.IsError);
        Assert.Empty(snapshot.Lines);
    }

    [Fact]
    public async Task TransportFailureBecomesConnectionError()
    {
        var files = new FakeFileSystem();
        var environment = new FakeEnvironment();
        files.Files[Path.Combine(environment.HomeDirectory, ".claude", ".credentials.json")] =
            """{"claudeAiOauth":{"accessToken":"tok"}}""";
        var provider = new ClaudeQuotaProvider(
            new ClaudeAuthStore(files, environment),
            new ClaudeUsageClient(new FakeHttp()),
            new FixedQuotaClock(Now));

        var snapshot = await provider.RefreshAsync(CancellationToken.None);

        Assert.Equal(ProviderErrorText.ConnectionFailed, snapshot.ErrorMessage);
    }
}
