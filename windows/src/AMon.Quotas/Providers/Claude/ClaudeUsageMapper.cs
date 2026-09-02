using System.Globalization;
using System.Text.Json;

namespace AMon.Quotas.Providers.Claude;

public static class ClaudeUsageMapper
{
    /// Session (5h), Weekly (7d), and Sonnet (7d) utilization windows with their reset times.
    public static IReadOnlyList<QuotaMetricLine> Map(JsonElement root)
    {
        var lines = new List<QuotaMetricLine>();
        AddWindow(lines, root, "five_hour", "Session", QuotaPeriod.SessionMs);
        AddWindow(lines, root, "seven_day", "Weekly", QuotaPeriod.WeekMs);
        AddWindow(lines, root, "seven_day_sonnet", "Sonnet", QuotaPeriod.WeekMs);
        return lines;
    }

    public static string? PlanName(string? subscriptionType) =>
        string.IsNullOrWhiteSpace(subscriptionType)
            ? null
            : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(subscriptionType.Replace('_', ' '));

    private static void AddWindow(ICollection<QuotaMetricLine> lines, JsonElement root, string property, string label, long periodMs)
    {
        if (QuotaJson.ObjectProperty(root, property) is not { } window
            || QuotaJson.Number(window, "utilization") is not { } used)
            return;
        lines.Add(new QuotaProgressLine(
            label,
            QuotaJson.ClampPercent(used),
            100,
            QuotaMetricKind.Percent,
            ResetsAt: QuotaTime.ParseIso8601(QuotaJson.String(window, "resets_at")),
            PeriodMilliseconds: periodMs));
    }
}
