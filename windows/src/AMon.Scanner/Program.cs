using System.Text.Json;
using AMon.Collectors;
using AMon.LocalData;

var config = await new ConfigStore().LoadAsync();
var paths = config.Paths;
var coordinator = new UsageScanCoordinator(UsageScannerFactory.Create(new UsageScannerPaths(
    paths.Claude,
    paths.Codex,
    paths.OpenCode,
    paths.Cursor,
    paths.Gemini,
    paths.Qwen,
    paths.Copilot)));
var results = await coordinator.ScanAsync(new UsageScanContext(
    DateTimeOffset.Now,
    TimeZoneInfo.Local));

var output = results.Select(summary => new
{
    tool = summary.Tool,
    pathExists = summary.PathExists,
    sessions = summary.Sessions,
    input = summary.Usage.InputTokens,
    output = summary.Usage.OutputTokens,
    cacheRead = summary.Usage.CacheReadTokens,
    cacheWrite = summary.Usage.CacheWriteTokens,
    reasoning = summary.Usage.ReasoningTokens,
    total = summary.Usage.TotalTokens,
    costUsd = summary.CostUsd,
    models = summary.ModelTotals,
    daily = summary.Daily.Select(day => new
    {
        date = day.Date.ToString("yyyy-MM-dd"),
        model = day.Model,
        input = day.Usage.InputTokens,
        output = day.Usage.OutputTokens,
        cacheRead = day.Usage.CacheReadTokens,
        cacheWrite = day.Usage.CacheWriteTokens,
        reasoning = day.Usage.ReasoningTokens,
        total = day.Usage.TotalTokens,
        costUsd = day.CostUsd,
    }),
    note = summary.Note,
});

Console.WriteLine(JsonSerializer.Serialize(output, new JsonSerializerOptions
{
    WriteIndented = true,
}));
