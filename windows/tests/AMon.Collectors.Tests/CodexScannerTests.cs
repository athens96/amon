using System.Text.Json;
using AMon.Collectors;
using AMon.Collectors.Scanners;
using AMon.Core;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class CodexScannerTests
{
    [Fact]
    public async Task UsesLastCumulativeSnapshotAndScalesAllTurnDailyUsage()
    {
        using var fixture = new TemporaryDirectory();
        File.WriteAllLines(Path.Combine(fixture.Path, "rollout-session.jsonl"),
        [
            TurnContext("gpt-5-a"),
            TokenCount(
                "2026-07-25T01:00:00Z",
                Total(input: 80, cached: 20, output: 20, reasoning: 4, total: 100),
                Last(input: 80, cached: 20, output: 20, reasoning: 8, total: 100)),
            TurnContext("gpt-5-b"),
            TokenCount(
                "2026-07-26T01:00:00Z",
                Total(input: 120, cached: 20, output: 30, reasoning: 12, total: 150),
                Last(input: 80, cached: 20, output: 20, reasoning: 8, total: 100)),
        ]);

        var result = await new CodexScanner(fixture.Path).ScanAsync(Context());

        Assert.Equal(1, result.Sessions);
        Assert.Equal(100, result.Usage.InputTokens);
        Assert.Equal(20, result.Usage.CacheReadTokens);
        Assert.Equal(30, result.Usage.OutputTokens);
        Assert.Equal(12, result.Usage.ReasoningTokens);
        Assert.Equal(150, result.Usage.TotalTokens);
        Assert.Equal(150, result.ModelTotals["gpt-5-b"]);

        var firstDay = result.Daily.Single(day => day.Date == new DateOnly(2026, 7, 25));
        var secondDay = result.Daily.Single(day => day.Date == new DateOnly(2026, 7, 26));
        Assert.Equal("gpt-5-a", firstDay.Model);
        Assert.Equal("gpt-5-b", secondDay.Model);
        Assert.Equal(75, firstDay.Usage.TotalTokens);
        Assert.Equal(75, secondDay.Usage.TotalTokens);
        Assert.Equal(6, firstDay.Usage.ReasoningTokens);
        Assert.Equal(150, result.Daily.Sum(day => day.Usage.TotalTokens));
    }

    [Fact]
    public async Task ReasoningIsReportedButNeverDoubleCountedInTotal()
    {
        using var fixture = new TemporaryDirectory();
        File.WriteAllText(
            Path.Combine(fixture.Path, "rollout-reasoning.jsonl"),
            TokenCount(
                "2026-07-26T01:00:00Z",
                Total(input: 50, cached: 10, output: 20, reasoning: 15, total: 70),
                Last(input: 50, cached: 10, output: 20, reasoning: 15, total: 70)));

        var result = await new CodexScanner(fixture.Path).ScanAsync(Context());

        Assert.Equal(40, result.Usage.InputTokens);
        Assert.Equal(10, result.Usage.CacheReadTokens);
        Assert.Equal(20, result.Usage.OutputTokens);
        Assert.Equal(15, result.Usage.ReasoningTokens);
        Assert.Equal(70, result.Usage.TotalTokens);
    }

    [Fact]
    public async Task Warm_cache_mutation_and_deletion_match_cold_all_turn_scaling()
    {
        using var fixture = new TemporaryDirectory();
        var firstPath = Path.Combine(fixture.Path, "rollout-a.jsonl");
        var secondPath = Path.Combine(fixture.Path, "rollout-b.jsonl");
        WriteScaledSession(firstPath, "gpt-a", authoritativeTotal: 150);
        File.WriteAllLines(secondPath,
        [
            TurnContext("gpt-b"),
            TokenCount(
                "2026-07-26T03:00:00Z",
                Total(40, 10, 10, 2, 50),
                Last(40, 10, 10, 2, 50)),
        ]);
        var scanner = new CodexScanner(fixture.Path);

        var cold = await scanner.ScanAsync(Context());
        var warm = await scanner.ScanAsync(Context());

        AssertEquivalent(cold, warm);
        Assert.Equal(200, warm.Usage.TotalTokens);
        Assert.Equal(200, warm.Daily.Sum(static day => day.Usage.TotalTokens));
        Assert.Equal(2, scanner.CachedFileParseCount);

        WriteScaledSession(firstPath, "gpt-a-mutated", authoritativeTotal: 300);
        var mutatedCached = await scanner.ScanAsync(Context());
        var mutatedCold = await new CodexScanner(fixture.Path).ScanAsync(Context());

        AssertEquivalent(mutatedCold, mutatedCached);
        Assert.Equal(350, mutatedCached.Usage.TotalTokens);
        Assert.Equal(350, mutatedCached.Daily.Sum(static day => day.Usage.TotalTokens));
        Assert.Equal(3, scanner.CachedFileParseCount);

        File.Delete(secondPath);
        var deletedCached = await scanner.ScanAsync(Context());
        var deletedCold = await new CodexScanner(fixture.Path).ScanAsync(Context());

        AssertEquivalent(deletedCold, deletedCached);
        Assert.Equal(300, deletedCached.Usage.TotalTokens);
        Assert.Equal(300, deletedCached.Daily.Sum(static day => day.Usage.TotalTokens));
        Assert.Equal(1, deletedCached.Sessions);
        Assert.Equal(3, scanner.CachedFileParseCount);
    }

    [Fact]
    public async Task ParameterlessScannerUsesCodexHomeOverride()
    {
        using var fixture = new TemporaryDirectory();
        var sessions = Directory.CreateDirectory(Path.Combine(fixture.Path, "sessions")).FullName;
        File.WriteAllText(
            Path.Combine(sessions, "rollout-env.jsonl"),
            TokenCount(
                "2026-07-26T01:00:00Z",
                Total(input: 8, cached: 3, output: 2, reasoning: 1, total: 10),
                Last(input: 8, cached: 3, output: 2, reasoning: 1, total: 10)));
        var previous = Environment.GetEnvironmentVariable("CODEX_HOME");

        try
        {
            Environment.SetEnvironmentVariable("CODEX_HOME", fixture.Path);
            var result = await new CodexScanner().ScanAsync(Context());

            Assert.Equal(10, result.Usage.TotalTokens);
            Assert.Equal(1, result.Sessions);
        }
        finally
        {
            Environment.SetEnvironmentVariable("CODEX_HOME", previous);
        }
    }

    private static UsageScanContext Context() => new(
        new DateTimeOffset(2026, 7, 26, 12, 0, 0, TimeSpan.Zero),
        TimeZoneInfo.Utc,
        DailyWindowDays: 30);

    private static string TurnContext(string model) =>
        JsonSerializer.Serialize(new
        {
            type = "turn_context",
            payload = new
            {
                type = "turn_context",
                model,
            },
        });

    private static IReadOnlyDictionary<string, long> Total(
        long input,
        long cached,
        long output,
        long reasoning,
        long total) =>
        Tokens(input, cached, output, reasoning, total);

    private static IReadOnlyDictionary<string, long> Last(
        long input,
        long cached,
        long output,
        long reasoning,
        long total) =>
        Tokens(input, cached, output, reasoning, total);

    private static IReadOnlyDictionary<string, long> Tokens(
        long input,
        long cached,
        long output,
        long reasoning,
        long total) =>
        new Dictionary<string, long>
        {
            ["input_tokens"] = input,
            ["cached_input_tokens"] = cached,
            ["output_tokens"] = output,
            ["reasoning_output_tokens"] = reasoning,
            ["total_tokens"] = total,
        };

    private static string TokenCount(
        string timestamp,
        IReadOnlyDictionary<string, long> total,
        IReadOnlyDictionary<string, long> last) =>
        JsonSerializer.Serialize(new
        {
            timestamp,
            type = "event_msg",
            payload = new
            {
                type = "token_count",
                info = new
                {
                    total_token_usage = total,
                    last_token_usage = last,
                },
            },
        });

    private static void WriteScaledSession(
        string path,
        string model,
        long authoritativeTotal)
    {
        File.WriteAllLines(path,
        [
            TurnContext(model),
            TokenCount(
                "2026-07-25T01:00:00Z",
                Total(80, 20, 20, 4, 100),
                Last(80, 20, 20, 4, 100)),
            TokenCount(
                "2026-07-26T01:00:00Z",
                Total(
                    authoritativeTotal - 30,
                    20,
                    30,
                    8,
                    authoritativeTotal),
                Last(80, 20, 20, 4, 100)),
        ]);
    }

    private static void AssertEquivalent(ToolSummary expected, ToolSummary actual)
    {
        Assert.Equal(expected.Sessions, actual.Sessions);
        Assert.Equal(expected.Usage, actual.Usage);
        Assert.Equal(expected.CostUsd, actual.CostUsd);
        Assert.Equal(
            expected.ModelTotals.OrderBy(static pair => pair.Key),
            actual.ModelTotals.OrderBy(static pair => pair.Key));
        Assert.Equal(
            expected.Daily.OrderBy(static day => day.Date).ThenBy(static day => day.Model),
            actual.Daily.OrderBy(static day => day.Date).ThenBy(static day => day.Model));
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"amon-codex-tests-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
