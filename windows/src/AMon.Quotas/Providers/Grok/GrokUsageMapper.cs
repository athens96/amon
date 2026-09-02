using System.Globalization;
using System.Text.Json;

namespace AMon.Quotas.Providers.Grok;

/// Builds the two Grok card rows from `/v1/billing` and the plan name from `/v1/settings`.
public static class GrokUsageMapper
{
    /// `null` when the payload no longer carries the credit figures the card is built from.
    public static IReadOnlyList<QuotaMetricLine>? MapBilling(JsonElement root)
    {
        if (QuotaJson.ObjectProperty(root, "config") is not { } config
            || Units(config, "used") is not { } used
            || Units(config, "monthlyLimit") is not { } limit
            || limit <= 0
            || QuotaTime.ParseIso8601(QuotaJson.String(config, "billingPeriodEnd")) is not { } resetsAt)
        {
            return null;
        }

        // A SuperGrok account with no pay-as-you-go has no `onDemandCap` field at all; a missing or
        // non-numeric cap is the "Disabled" badge, not a broken payload.
        var onDemandCap = Units(config, "onDemandCap") ?? 0;

        return
        [
            new QuotaProgressLine(
                "Credits used",
                QuotaJson.ClampPercent(used / limit * 100),
                100,
                QuotaMetricKind.Percent,
                ResetsAt: resetsAt),
            new QuotaBadgeLine("Pay as you go", onDemandCap > 0 ? $"{FormatUnits(onDemandCap)} cap" : "Disabled"),
        ];
    }

    /// Best-effort plan name; `null` for any non-2xx, unparseable body, or missing tier.
    public static string? PlanName(QuotaHttpResponse response)
    {
        if (!response.IsSuccess)
            return null;
        using var document = QuotaJson.ParseObject(response.Body);
        return document is null ? null : QuotaJson.String(document.RootElement, "subscription_tier_display");
    }

    /// Grok wraps every credit figure as `{ "val": <number> }`.
    private static double? Units(JsonElement config, string name) =>
        QuotaJson.ObjectProperty(config, name) is { } wrapper ? QuotaJson.Number(wrapper, "val") : null;

    private static string FormatUnits(double value) =>
        Math.Round(value) == value
            ? ((long)value).ToString(CultureInfo.InvariantCulture)
            : value.ToString(CultureInfo.InvariantCulture);
}
