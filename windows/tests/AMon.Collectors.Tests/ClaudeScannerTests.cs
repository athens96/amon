using System.Text.Json;
using AMon.Collectors;
using AMon.Collectors.Scanners;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class ClaudeScannerTests
{
    [Fact]
    public async Task DedupUsesLastOccurrenceWithinFileAndFirstFileGlobally()
    {
        using var fixture = new TemporaryDirectory();
        var project = Directory.CreateDirectory(Path.Combine(fixture.Path, "project")).FullName;
        File.WriteAllLines(Path.Combine(project, "a.jsonl"),
        [
            ClaudeLine("msg-1", "req-1", 10, 2, 3, 4, "2026-07-25T01:00:00Z"),
            ClaudeLine("msg-1", "req-1", 20, 4, 6, 8, "2026-07-25T02:00:00Z"),
            ClaudeLine("msg-1", "req-2", 5, 1, 0, 0, "2026-07-25T03:00:00Z"),
        ]);
        File.WriteAllLines(Path.Combine(project, "b.jsonl"),
        [
            ClaudeLine("msg-1", "req-1", 30, 6, 9, 12, "2026-07-26T01:00:00Z"),
        ]);

        var result = await new ClaudeScanner(fixture.Path).ScanAsync(Context());

        Assert.True(result.PathExists);
        Assert.Equal(2, result.Sessions);
        Assert.Equal(25, result.Usage.InputTokens);
        Assert.Equal(5, result.Usage.OutputTokens);
        Assert.Equal(6, result.Usage.CacheReadTokens);
        Assert.Equal(8, result.Usage.CacheWriteTokens);
        Assert.Equal(44, result.Usage.TotalTokens);
        Assert.Equal(44, result.ModelTotals["claude-opus-4-8"]);
        Assert.Single(result.Daily);
        Assert.Equal(44, result.Daily.Single().Usage.TotalTokens);
        Assert.Equal(new DateOnly(2026, 7, 25), result.Daily.Single().Date);
    }

    [Fact]
    public async Task Cached_files_are_globally_merged_again_after_first_winner_is_deleted()
    {
        using var fixture = new TemporaryDirectory();
        var firstPath = Path.Combine(fixture.Path, "a.jsonl");
        var secondPath = Path.Combine(fixture.Path, "b.jsonl");
        File.WriteAllText(
            firstPath,
            ClaudeLine("shared", "request", 10, 0, 0, 0, "2026-07-25T01:00:00Z"));
        File.WriteAllText(
            secondPath,
            ClaudeLine("shared", "request", 30, 0, 0, 0, "2026-07-25T02:00:00Z"));
        var scanner = new ClaudeScanner(fixture.Path);

        var first = await scanner.ScanAsync(Context());
        var unchanged = await scanner.ScanAsync(Context());

        Assert.Equal(10, first.Usage.TotalTokens);
        Assert.Equal(first.Usage, unchanged.Usage);
        Assert.Equal(2, scanner.CachedFileParseCount);

        File.Delete(firstPath);
        var afterDelete = await scanner.ScanAsync(Context());

        Assert.Equal(30, afterDelete.Usage.TotalTokens);
        Assert.Equal(1, afterDelete.Sessions);
        Assert.Equal(2, scanner.CachedFileParseCount);
    }

    [Fact]
    public async Task SyntheticUsageCountsButIsExcludedFromModelTotals()
    {
        using var fixture = new TemporaryDirectory();
        File.WriteAllText(
            Path.Combine(fixture.Path, "synthetic.jsonl"),
            ClaudeLine(
                "synthetic",
                "req",
                9,
                1,
                0,
                0,
                "2026-07-26T01:00:00Z",
                model: "<synthetic>"));

        var result = await new ClaudeScanner(fixture.Path).ScanAsync(Context());

        Assert.Equal(10, result.Usage.TotalTokens);
        Assert.DoesNotContain("<synthetic>", result.ModelTotals.Keys);
    }

    [Fact]
    public async Task Active_session_file_can_be_read_while_writer_keeps_it_open()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "active.jsonl");
        await File.WriteAllTextAsync(
            path,
            ClaudeLine("active", "req", 8, 2, 0, 0, "2026-07-26T01:00:00Z"));
        await using var writer = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Write,
            FileShare.ReadWrite | FileShare.Delete);

        var result = await new ClaudeScanner(fixture.Path).ScanAsync(Context());

        Assert.Equal(10, result.Usage.TotalTokens);
    }

    [Fact]
    public async Task ParameterlessScannerUsesClaudeConfigDirectoryOverride()
    {
        using var fixture = new TemporaryDirectory();
        var projects = Directory.CreateDirectory(Path.Combine(fixture.Path, "projects")).FullName;
        File.WriteAllText(
            Path.Combine(projects, "session.jsonl"),
            ClaudeLine("msg", "req", 7, 3, 0, 0, "2026-07-26T01:00:00Z"));
        var previous = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");

        try
        {
            Environment.SetEnvironmentVariable("CLAUDE_CONFIG_DIR", fixture.Path);
            var result = await new ClaudeScanner().ScanAsync(Context());

            Assert.Equal(10, result.Usage.TotalTokens);
            Assert.Equal(1, result.Sessions);
        }
        finally
        {
            Environment.SetEnvironmentVariable("CLAUDE_CONFIG_DIR", previous);
        }
    }

    [Fact]
    public async Task MissingExplicitRootReturnsAPathDiagnostic()
    {
        var root = Path.Combine(Path.GetTempPath(), $"missing-claude-{Guid.NewGuid():N}");

        var result = await new ClaudeScanner(root).ScanAsync(Context());

        Assert.False(result.PathExists);
        Assert.False(result.ScanSucceeded);
        Assert.Equal("경로를 찾을 수 없습니다", result.Note);
        Assert.Equal(0, result.Sessions);
    }

    private static UsageScanContext Context() => new(
        new DateTimeOffset(2026, 7, 26, 12, 0, 0, TimeSpan.Zero),
        TimeZoneInfo.Utc,
        DailyWindowDays: 30);

    private static string ClaudeLine(
        string messageId,
        string requestId,
        long input,
        long output,
        long cacheRead,
        long cacheWrite,
        string timestamp,
        string model = "claude-opus-4-8") =>
        JsonSerializer.Serialize(new
        {
            type = "assistant",
            timestamp,
            requestId,
            message = new
            {
                id = messageId,
                model,
                usage = new
                {
                    input_tokens = input,
                    output_tokens = output,
                    cache_creation_input_tokens = cacheWrite,
                    cache_read_input_tokens = cacheRead,
                },
            },
        });

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"amon-claude-tests-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
