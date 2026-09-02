using System.Text.Json;

namespace AMon.Quotas.Providers.ZAI;

/// Builds metric lines from the Z.ai `/api/monitor/usage/quota/limit` payload and the plan name from
/// `/api/biz/subscription/list`:
/// - a `TOKENS_LIMIT` entry whose window is sub-daily (`unit: 3`, hours) is the 5-hour session meter,
/// - a `TOKENS_LIMIT` entry whose window is multi-day (`unit: 6`, weeks) is the weekly meter,
/// - a `TIME_LIMIT` entry (`unit: 5`, monthly) is the web-search count meter (used / limit).
/// Both endpoints are undocumented internal APIs used by Z.ai's own subscription UI.
public static class ZaiUsageMapper
{
    /// True when a 2xx quota body is the "valid key, but no GLM Coding Plan" signal: Z.ai answers
    /// `{"success":false,"code":500,"msg":"…coding plan"}` with no `data`. Matched on the structured
    /// `success:false` plus the ASCII "coding plan" phrase so an unrelated failure doesn't trip it.
    public static bool IsNoCodingPlan(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        if (document is null || QuotaJson.Bool(document.RootElement, "success") is not false)
            return false;
        return (QuotaJson.String(document.RootElement, "msg") ?? string.Empty)
            .Contains("coding plan", StringComparison.OrdinalIgnoreCase);
    }

    /// Session + weekly + web-search meters. Emits the "No usage data" placeholder when the payload
    /// carries no usable limits.
    public static IReadOnlyList<QuotaMetricLine> MapQuota(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        if (document is null)
            return [NoUsageData];

        // The limits array lives under `data.limits`; the legacy plugin also tolerated the root
        // object being the container directly, so honor both.
        var container = QuotaJson.ObjectProperty(document.RootElement, "data") ?? document.RootElement;
        if (QuotaJson.ArrayProperty(container, "limits") is not { } limits)
            return [NoUsageData];

        var lines = new List<QuotaMetricLine>();
        foreach (var entry in limits.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.Object || !IsType(entry, "TOKENS_LIMIT"))
                continue;
            // A sub-daily window is the session meter, a multi-day window the weekly one; an
            // unrecognized unit is skipped so a future unit value can't overwrite a known meter.
            if (PeriodDurationMs(entry) is not { } periodMs)
                continue;
            lines.Add(periodMs < QuotaPeriod.DayMs
                ? PercentLine(entry, "Session", QuotaPeriod.SessionMs)
                : PercentLine(entry, "Weekly", QuotaPeriod.WeekMs));
        }

        foreach (var entry in limits.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.Object || !IsType(entry, "TIME_LIMIT"))
                continue;
            lines.Add(WebSearchLine(entry));
            break;
        }

        return lines.Count > 0 ? lines : [NoUsageData];
    }

    /// `productName` from the first subscription entry (e.g. "GLM Coding Max").
    public static string? PlanName(string? body)
    {
        if (body is null)
            return null;
        using var document = QuotaJson.ParseObject(body);
        if (document is null || QuotaJson.ArrayProperty(document.RootElement, "data") is not { } list)
            return null;
        foreach (var entry in list.EnumerateArray())
            return QuotaJson.String(entry, "productName");
        return null;
    }

    private static QuotaBadgeLine NoUsageData => new("Status", "No usage data");

    /// A limit entry matches by `type` or `name`; Z.ai's payload has used either across revisions.
    private static bool IsType(JsonElement entry, string type) =>
        QuotaJson.String(entry, "type") == type || QuotaJson.String(entry, "name") == type;

    /// Resolve a `(unit, number)` window to milliseconds. `unit` is Z.ai's internal time-unit code.
    private static long? PeriodDurationMs(JsonElement entry)
    {
        if (QuotaJson.Number(entry, "unit") is not { } unit || QuotaJson.Number(entry, "number") is not { } number)
            return null;
        double unitMs = unit switch
        {
            3 => 60d * 60 * 1000,          // hours
            4 => QuotaPeriod.DayMs,        // days
            6 => QuotaPeriod.WeekMs,       // weeks
            5 => QuotaPeriod.MonthMs,      // months
            _ => 0,
        };
        return unitMs > 0 ? (long)(unitMs * number) : null;
    }

    private static QuotaProgressLine PercentLine(JsonElement entry, string label, long periodMs) =>
        new(
            label,
            QuotaJson.ClampPercent(QuotaJson.Number(entry, "percentage") ?? 0),
            100,
            QuotaMetricKind.Percent,
            ResetsAt: QuotaTime.FromEpochMilliseconds(QuotaJson.Number(entry, "nextResetTime")),
            PeriodMilliseconds: periodMs);

    /// TIME_LIMIT → a count meter (used / limit) for monthly web-search/reader calls.
    private static QuotaProgressLine WebSearchLine(JsonElement entry) =>
        new(
            "Web Searches",
            Math.Max(0, QuotaJson.Number(entry, "currentValue") ?? 0),
            Math.Max(0, QuotaJson.Number(entry, "usage") ?? 0),
            QuotaMetricKind.Count,
            CountSuffix: "searches",
            ResetsAt: QuotaTime.FromEpochMilliseconds(QuotaJson.Number(entry, "nextResetTime")),
            PeriodMilliseconds: QuotaPeriod.MonthMs);
}
