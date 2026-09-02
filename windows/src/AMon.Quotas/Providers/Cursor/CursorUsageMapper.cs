using System.Text.Json;

namespace AMon.Quotas.Providers.Cursor;

/// `GetCurrentPeriodUsage` → percent meters. Team seats carry `totalPercentUsed` only (no cent
/// limit), individual plans carry `limit`/`totalSpend`; both collapse to a percent meter.
public static class CursorUsageMapper
{
    public static IReadOnlyList<QuotaMetricLine> Map(JsonElement root)
    {
        var lines = new List<QuotaMetricLine>();
        var reset = QuotaTime.FromEpochMilliseconds(QuotaJson.Number(root, "billingCycleEnd"));
        if (QuotaJson.ObjectProperty(root, "planUsage") is { } planUsage)
        {
            if (QuotaJson.Number(planUsage, "totalPercentUsed") is { } total)
                lines.Add(Percent("Total usage", total, reset));
            else if (QuotaJson.Number(planUsage, "limit") is { } limit && limit > 0)
            {
                var spent = QuotaJson.Number(planUsage, "totalSpend")
                    ?? Math.Max(0, limit - (QuotaJson.Number(planUsage, "remaining") ?? limit));
                lines.Add(Percent("Total usage", spent / limit * 100, reset));
            }
            if (QuotaJson.Number(planUsage, "autoPercentUsed") is { } auto)
                lines.Add(Percent("Auto usage", auto, reset));
            if (QuotaJson.Number(planUsage, "apiPercentUsed") is { } api)
                lines.Add(Percent("API usage", api, reset));
        }
        return lines;
    }

    private static QuotaProgressLine Percent(string label, double used, DateTimeOffset? reset) =>
        new(label, QuotaJson.ClampPercent(used), 100, QuotaMetricKind.Percent, ResetsAt: reset, PeriodMilliseconds: QuotaPeriod.MonthMs);
}
