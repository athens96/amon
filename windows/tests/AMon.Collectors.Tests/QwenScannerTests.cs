using AMon.Collectors.Scanners;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class QwenScannerTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"qwen-{Guid.NewGuid():N}");

    [Fact]
    public async Task SeparatesPromptCacheAndCountsEveryAssistantUsageLine()
    {
        Directory.CreateDirectory(Path.Combine(_root, "project"));
        await File.WriteAllTextAsync(Path.Combine(_root, "project", "one.jsonl"), """
            {"type":"user","usageMetadata":{"promptTokenCount":999}}
            {"type":"assistant","timestamp":"2026-07-26T01:00:00Z","model":"qwen-a","usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":40,"candidatesTokenCount":5,"thoughtsTokenCount":2}}
            {"type":"assistant","timestamp":"2026-07-26T02:00:00Z","message":{"model":"qwen-b"},"usageMetadata":{"promptTokenCount":20,"cachedContentTokenCount":30,"candidatesTokenCount":3,"thoughtsTokenCount":1}}
            """);
        var context = new UsageScanContext(
            new DateTimeOffset(2026, 7, 26, 12, 0, 0, TimeSpan.Zero), TimeZoneInfo.Utc);

        var result = await new QwenScanner(_root).ScanAsync(context);

        Assert.Equal(1, result.Sessions);
        Assert.Equal(60, result.Usage.InputTokens);
        Assert.Equal(70, result.Usage.CacheReadTokens);
        Assert.Equal(11, result.Usage.OutputTokens);
        Assert.Equal(3, result.Usage.ReasoningTokens);
        Assert.Equal(141, result.Usage.TotalTokens);
        Assert.Equal(107, result.ModelTotals["qwen-a"]);
        Assert.Equal(34, result.ModelTotals["qwen-b"]);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }
}
