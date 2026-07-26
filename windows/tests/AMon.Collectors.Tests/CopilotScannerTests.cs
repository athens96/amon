using AMon.Collectors.Scanners;
using System.Text.Json;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class CopilotScannerTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"copilot-{Guid.NewGuid():N}");

    [Fact]
    public async Task UsesNewLayoutShutdownOnlyAndSeparatesCachedInput()
    {
        Directory.CreateDirectory(Path.Combine(_root, "same"));
        await File.WriteAllTextAsync(Path.Combine(_root, "same.jsonl"), Shutdown("gpt-old", 999, 0, 0, 0));
        await File.WriteAllTextAsync(Path.Combine(_root, "same", "events.jsonl"), string.Join('\n',
            """{"type":"session.start","timestamp":"2026-07-26T01:00:00Z","data":{"modelMetrics":{"ignored":{"usage":{"inputTokens":999}}}}}""",
            Shutdown("claude-sonnet-4.6", 100, 30, 20, 10)));
        await File.WriteAllTextAsync(Path.Combine(_root, "flat.jsonl"), Shutdown("gpt-5", 50, 5, 5, 4));
        var context = new UsageScanContext(
            new DateTimeOffset(2026, 7, 26, 12, 0, 0, TimeSpan.Zero), TimeZoneInfo.Utc);

        var result = await new CopilotScanner(_root).ScanAsync(context);

        Assert.Equal(2, result.Sessions);
        Assert.Equal(90, result.Usage.InputTokens);
        Assert.Equal(35, result.Usage.CacheReadTokens);
        Assert.Equal(25, result.Usage.CacheWriteTokens);
        Assert.Equal(14, result.Usage.OutputTokens);
        Assert.Equal(164, result.Usage.TotalTokens);
        Assert.Equal(4, result.Usage.ReasoningTokens);
        Assert.Equal(110, result.ModelTotals["claude-sonnet-4-6"]);
        Assert.Equal(54, result.ModelTotals["gpt-5"]);
        Assert.DoesNotContain("gpt-old", result.ModelTotals.Keys);
    }

    private static string Shutdown(string model, long input, long read, long write, long output) =>
        JsonSerializer.Serialize(new
        {
            type = "session.shutdown",
            timestamp = "2026-07-26T02:00:00Z",
            data = new
            {
                modelMetrics = new Dictionary<string, object>
                {
                    [model] = new
                    {
                        usage = new
                        {
                            inputTokens = input,
                            cacheReadTokens = read,
                            cacheWriteTokens = write,
                            outputTokens = output,
                            reasoningTokens = 2
                        }
                    }
                }
            }
        });

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }
}
