namespace AMon.Core;

public readonly record struct TokenUsage(
    long InputTokens,
    long OutputTokens,
    long CacheReadTokens = 0,
    long CacheWriteTokens = 0,
    long ReasoningTokens = 0,
    long? ReportedTotalTokens = null)
{
    // Reasoning is reported separately but is already included in output by providers.
    public long TotalTokens => ReportedTotalTokens ?? checked(
        InputTokens + OutputTokens + CacheReadTokens + CacheWriteTokens);

    public TokenUsage Add(TokenUsage other) => new(
        checked(InputTokens + other.InputTokens),
        checked(OutputTokens + other.OutputTokens),
        checked(CacheReadTokens + other.CacheReadTokens),
        checked(CacheWriteTokens + other.CacheWriteTokens),
        checked(ReasoningTokens + other.ReasoningTokens),
        ReportedTotalTokens is not null || other.ReportedTotalTokens is not null
            ? checked(TotalTokens + other.TotalTokens)
            : null);
}

public sealed record UsageDaily(
    DateOnly Date,
    string Model,
    TokenUsage Usage,
    decimal CostUsd = 0);

public sealed record ToolSummary(
    string Tool,
    string DisplayName,
    IReadOnlyList<UsageDaily> Daily,
    long Sessions = 0,
    DateTimeOffset? LastActivity = null,
    string? Note = null,
    bool PathExists = false,
    TokenUsage? TotalUsage = null,
    decimal? TotalCostUsd = null,
    IReadOnlyDictionary<string, long>? Models = null,
    bool ScanSucceeded = true)
{
    public TokenUsage Usage =>
        TotalUsage ?? Daily.Aggregate(default(TokenUsage), static (total, day) => total.Add(day.Usage));

    public decimal CostUsd => TotalCostUsd ?? Daily.Sum(static day => day.CostUsd);

    public IReadOnlyDictionary<string, long> ModelTotals { get; } =
        Models ?? new Dictionary<string, long>();
}

public sealed record UsageDatabaseMetadata(
    string Machine,
    string AppVersion,
    string DeviceId,
    DateTimeOffset GeneratedAt);
