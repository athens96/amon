using System.Text.Json;

namespace AMon.Quotas.Providers.OpenRouter;

/// Builds metric lines from the OpenRouter `/credits` and `/key` payloads. Each endpoint maps
/// independently so either one failing still leaves the other's rows usable.
public static class OpenRouterUsageMapper
{
    /// Credits meter + Balance from `/credits`. Empty when the payload carries no usable total.
    public static IReadOnlyList<QuotaMetricLine> CreditsLines(JsonElement data)
    {
        if (QuotaJson.Number(data, "total_usage") is not { } totalUsage)
            return [];

        var used = Math.Max(0, totalUsage);
        // `total_credits` is the lifetime amount added to the account; the balance is what's left.
        var totalCredits = Math.Max(0, QuotaJson.Number(data, "total_credits") ?? 0);

        var lines = new List<QuotaMetricLine>();
        // Only a positive ceiling makes a meter meaningful; a never-topped-up account still gets Balance.
        if (totalCredits > 0)
            lines.Add(new QuotaProgressLine("Credits", used, totalCredits, QuotaMetricKind.Dollars));
        lines.Add(new QuotaValuesLine(
            "Balance",
            [new QuotaMetricValue(Math.Max(0, totalCredits - used), QuotaMetricKind.Dollars)]));
        return lines;
    }

    /// Period spend + optional per-key cap from `/key`, plus the tier surfaced as the plan name.
    public static (string? Plan, IReadOnlyList<QuotaMetricLine> Lines) KeyMetrics(JsonElement data)
    {
        var lines = new List<QuotaMetricLine>();
        AppendSpend(lines, data, "usage_daily", "Today");
        AppendSpend(lines, data, "usage_weekly", "This Week");
        AppendSpend(lines, data, "usage_monthly", "This Month");

        if (QuotaJson.Number(data, "limit") is { } limit && limit > 0)
        {
            lines.Add(new QuotaProgressLine(
                "Key Limit",
                Math.Max(0, QuotaJson.Number(data, "usage") ?? 0),
                limit,
                QuotaMetricKind.Dollars));
        }

        var plan = QuotaJson.Bool(data, "is_free_tier") switch
        {
            true => "Free tier",
            false => "Pay as you go",
            null => null,
        };
        return (plan, lines);
    }

    private static void AppendSpend(ICollection<QuotaMetricLine> lines, JsonElement data, string property, string label)
    {
        if (QuotaJson.Number(data, property) is not { } amount)
            return;
        lines.Add(new QuotaValuesLine(label, [new QuotaMetricValue(Math.Max(0, amount), QuotaMetricKind.Dollars)]));
    }
}
