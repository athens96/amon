using System.Globalization;
using System.Text.Json;

namespace AMon.Quotas.Providers.Codex;

public static class CodexUsageMapper
{
    /// Session (primary 5h window) and Weekly (secondary 7d window) from `rate_limit`.
    public static IReadOnlyList<QuotaMetricLine> Map(JsonElement root)
    {
        var lines = new List<QuotaMetricLine>();
        if (QuotaJson.ObjectProperty(root, "rate_limit") is { } rateLimit)
        {
            AddWindow(lines, rateLimit, "primary_window", "Session", QuotaPeriod.SessionMs);
            AddWindow(lines, rateLimit, "secondary_window", "Weekly", QuotaPeriod.WeekMs);
        }
        return lines;
    }

    public static string? PlanName(JsonElement root)
    {
        var plan = QuotaJson.String(root, "plan_type");
        return plan is null
            ? null
            : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(plan.Replace('_', ' '));
    }

    private static void AddWindow(ICollection<QuotaMetricLine> lines, JsonElement rateLimit, string property, string label, long periodMs)
    {
        if (QuotaJson.ObjectProperty(rateLimit, property) is not { } window
            || QuotaJson.Number(window, "used_percent") is not { } used)
            return;
        var reset = QuotaTime.FromEpochSeconds(QuotaJson.Number(window, "reset_at"))
            ?? QuotaTime.FromEpochSeconds(QuotaJson.Number(window, "resets_at"));
        lines.Add(new QuotaProgressLine(
            label,
            QuotaJson.ClampPercent(used),
            100,
            QuotaMetricKind.Percent,
            ResetsAt: reset,
            PeriodMilliseconds: periodMs));
    }
}
