using System.Text.Json;

namespace AMon.Quotas.Providers.Devin;

public sealed record DevinMappedUsage(string? Plan, IReadOnlyList<QuotaMetricLine> Lines);

/// Normalizes `GetUserStatus` into meters. Devin reports quota as percent *remaining*, so every
/// quota row is flipped to percent *used*. `null` means "nothing mappable here" — the provider
/// treats that the same as any other unavailable response.
public static class DevinUsageMapper
{
    public const long DayPeriodMs = QuotaPeriod.DayMs;
    public const long WeekPeriodMs = QuotaPeriod.WeekMs;

    public static DevinMappedUsage? MapUserStatusResponse(JsonElement root) =>
        QuotaJson.ObjectProperty(root, "userStatus") is { } userStatus ? MapUserStatus(userStatus) : null;

    public static DevinMappedUsage? MapUserStatus(JsonElement userStatus)
    {
        var planStatus = QuotaJson.ObjectProperty(userStatus, "planStatus");
        var planInfo = planStatus is { } status ? QuotaJson.ObjectProperty(status, "planInfo") : null;
        var plan = (planInfo is { } info ? QuotaJson.String(info, "planName") : null) ?? "Unknown";
        var hideDailyQuota = planInfo is { } flags && StrictBool(flags, "hideDailyQuota") == true;

        var dailyRemaining = Number(planStatus, "dailyQuotaRemainingPercent");
        var weeklyRemaining = Number(planStatus, "weeklyQuotaRemainingPercent");
        var dailyReset = hideDailyQuota ? null : QuotaTime.FromEpochSeconds(Number(planStatus, "dailyQuotaResetAtUnix"));
        var weeklyReset = QuotaTime.FromEpochSeconds(Number(planStatus, "weeklyQuotaResetAtUnix"));
        var extraUsageBalance = DollarsFromMicros(Number(planStatus, "overageBalanceMicros"));

        var lines = new List<QuotaMetricLine>();
        if (!hideDailyQuota && dailyRemaining is { } daily)
            lines.Add(QuotaLine("Daily quota", daily, dailyReset, DayPeriodMs));

        if (weeklyRemaining is { } weekly)
        {
            lines.Add(QuotaLine("Weekly quota", weekly, weeklyReset, WeekPeriodMs));
        }
        else if (hideDailyQuota && dailyRemaining is { } hidden)
        {
            // No weekly quota in the response: surface the (hidden) daily quota in the Weekly row so
            // the tile stays meaningful. Still flipped from remaining→used, just like every quota row.
            lines.Add(QuotaLine("Weekly quota", hidden, weeklyReset, WeekPeriodMs));
        }

        if (extraUsageBalance is { } balance)
        {
            // Carried raw (not a baked currency string) so it formats through the shared metric
            // formatter and picks up the same compact shorthand as the spend tiles.
            lines.Add(new QuotaValuesLine("Extra usage balance", [new QuotaMetricValue(balance, QuotaMetricKind.Dollars)]));
        }

        return lines.Count == 0 ? null : new DevinMappedUsage(plan, lines);
    }

    /// Devin reports quota as percent *remaining*; the tile shows percent *used*, so every quota row
    /// flips `100 - remaining` (clamped) — including the weekly-from-daily fallback above.
    private static QuotaMetricLine QuotaLine(string label, double remaining, DateTimeOffset? resetsAt, long periodMs) =>
        new QuotaProgressLine(
            label,
            QuotaJson.ClampPercent(100 - remaining),
            100,
            QuotaMetricKind.Percent,
            ResetsAt: resetsAt,
            PeriodMilliseconds: periodMs);

    /// An overage balance in dollars; `null` only when the field is missing or non-numeric (truly no
    /// data). A present balance of zero stays a real, measured zero ("$0.00") — not "No data".
    private static double? DollarsFromMicros(double? micros) =>
        micros is { } value ? Math.Max(0, value) / 1_000_000 : null;

    private static double? Number(JsonElement? element, string name) =>
        element is { } value ? QuotaJson.Number(value, name) : null;

    /// Devin sends `hideDailyQuota` as a real boolean; like the macOS mapper, only `true`/`false`
    /// (or those exact strings) count — a numeric `1` must not silently hide the daily meter.
    private static bool? StrictBool(System.Text.Json.JsonElement element, string name)
    {
        if (!QuotaJson.TryProperty(element, name, out var value))
            return null;
        return value.ValueKind switch
        {
            System.Text.Json.JsonValueKind.True => true,
            System.Text.Json.JsonValueKind.False => false,
            System.Text.Json.JsonValueKind.String => value.GetString()?.Trim().ToLowerInvariant() switch
            {
                "true" => true,
                "false" => false,
                _ => null,
            },
            _ => null,
        };
    }
}
