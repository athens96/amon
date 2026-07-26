using AMon.Core;

namespace AMon.Collectors;

internal readonly record struct ParsedUsageEntry(
    TokenUsage Usage,
    DateTimeOffset? Timestamp,
    string? Model,
    decimal CostUsd = 0,
    bool IncludeModelTotal = true);

internal sealed record ParsedFileContribution(
    IReadOnlyList<ParsedUsageEntry> Entries,
    IReadOnlyList<string> SessionIds)
{
    public static ParsedFileContribution Empty { get; } = new([], []);

    public void Apply(ScannerResultBuilder builder)
    {
        foreach (var entry in Entries)
        {
            builder.Add(
                entry.Usage,
                entry.Timestamp,
                entry.Model,
                entry.CostUsd,
                entry.IncludeModelTotal);
        }
    }
}
