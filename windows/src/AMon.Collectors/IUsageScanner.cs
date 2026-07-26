using AMon.Core;

namespace AMon.Collectors;

public interface IUsageScanner
{
    string Tool { get; }

    Task<ToolSummary> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default);
}

public sealed record UsageScanContext(
    DateTimeOffset Now,
    TimeZoneInfo TimeZone,
    int DailyWindowDays = 30)
{
    public DateOnly Today => DateOnly.FromDateTime(
        TimeZoneInfo.ConvertTime(Now, TimeZone).DateTime);

    public DateOnly WindowStart => Today.AddDays(1 - Math.Max(1, DailyWindowDays));

    public DateOnly LocalDate(DateTimeOffset timestamp) => DateOnly.FromDateTime(
        TimeZoneInfo.ConvertTime(timestamp, TimeZone).DateTime);
}
