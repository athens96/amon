using AMon.Collectors.Scanners;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class GeminiScannerTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"gemini-{Guid.NewGuid():N}");
    private static readonly UsageScanContext Context =
        new(new DateTimeOffset(2026, 7, 26, 12, 0, 0, TimeSpan.Zero), TimeZoneInfo.Utc);

    [Fact]
    public async Task AppliesCumulativeDeltasResetsAndJsonlLastWinsInOriginalOrder()
    {
        var chats = Path.Combine(_root, "tmp", "hash", "chats");
        Directory.CreateDirectory(chats);
        await File.WriteAllTextAsync(Path.Combine(chats, "session-one.jsonl"), """
            {"sessionId":"one"}
            {"id":"a","type":"gemini","timestamp":"2026-07-26T01:00:00Z","model":"gemini-2","tokens":{"input":100,"cached":40,"output":1,"thoughts":1}}
            {"id":"b","type":"gemini","timestamp":"2026-07-26T02:00:00Z","model":"gemini-2","tokens":{"input":150,"cached":70,"output":2,"thoughts":1}}
            {"id":"a","type":"gemini","timestamp":"2026-07-26T01:00:00Z","model":"gemini-2","tokens":{"input":120,"cached":50,"output":3,"thoughts":2}}
            {"id":"c","type":"gemini","timestamp":"2026-07-26T03:00:00Z","model":"gemini-2","tokens":{"input":20,"cached":5,"output":4,"thoughts":2}}
            """);

        var result = await new GeminiScanner(Path.Combine(_root, "tmp")).ScanAsync(Context);

        Assert.Equal(1, result.Sessions);
        Assert.Equal(170, result.Usage.InputTokens);
        Assert.Equal(75, result.Usage.CacheReadTokens);
        Assert.Equal(14, result.Usage.OutputTokens);
        Assert.Equal(5, result.Usage.ReasoningTokens);
        Assert.Equal(259, result.Usage.TotalTokens);
        Assert.Equal(259, result.ModelTotals["gemini-2"]);
    }

    [Fact]
    public async Task ParameterlessScannerUsesGeminiDirectoryOverrideTmpChild()
    {
        var configured = Path.Combine(_root, "configured");
        var chats = Path.Combine(configured, "tmp", "hash", "chats");
        Directory.CreateDirectory(chats);
        await File.WriteAllTextAsync(Path.Combine(chats, "session-env.json"), """
            {"sessionId":"env","messages":[
              {"id":"one","type":"gemini","timestamp":"2026-07-26T01:00:00Z",
               "model":"gemini-env","tokens":{"input":7,"cached":3,"output":2,"thoughts":1}}
            ]}
            """);
        var previous = Environment.GetEnvironmentVariable("GEMINI_DIR");
        try
        {
            Environment.SetEnvironmentVariable("GEMINI_DIR", configured);
            var result = await new GeminiScanner().ScanAsync(Context);
            Assert.True(result.PathExists);
            Assert.Equal(1, result.Sessions);
            Assert.Equal(13, result.Usage.TotalTokens);
        }
        finally
        {
            Environment.SetEnvironmentVariable("GEMINI_DIR", previous);
        }
    }

    [Fact]
    public async Task Malformed_json_change_keeps_last_good_until_document_recovers()
    {
        var chats = Path.Combine(_root, "tmp", "hash", "chats");
        Directory.CreateDirectory(chats);
        var path = Path.Combine(chats, "session-live.json");
        await File.WriteAllTextAsync(path, """
            {"sessionId":"live","messages":[
              {"id":"one","type":"gemini","timestamp":"2026-07-26T01:00:00Z",
               "model":"gemini-live","tokens":{"input":7,"cached":3,"output":2,"thoughts":1}}
            ]}
            """);
        var scanner = new GeminiScanner(Path.Combine(_root, "tmp"));

        var fresh = await scanner.ScanAsync(Context);
        await File.WriteAllTextAsync(
            path,
            """{"sessionId":"live","messages":[{"id":"partial","type":"gemini"}""");
        var stale = await scanner.ScanAsync(Context);

        Assert.Equal(fresh.Usage, stale.Usage);
        Assert.Equal(1, scanner.CachedFileParseCount);

        await File.WriteAllTextAsync(path, """
            {"sessionId":"live","messages":[
              {"id":"two","type":"gemini","timestamp":"2026-07-26T02:00:00Z",
               "model":"gemini-live","tokens":{"input":20,"cached":4,"output":5,"thoughts":2}}
            ]}
            """);
        var recovered = await scanner.ScanAsync(Context);

        Assert.Equal(31, recovered.Usage.TotalTokens);
        Assert.Equal(2, scanner.CachedFileParseCount);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }
}
