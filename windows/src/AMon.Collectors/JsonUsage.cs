using System.Globalization;
using System.Text.Json;
using AMon.Core;

namespace AMon.Collectors;

internal static class JsonUsage
{
    public static long Int64(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value))
            return 0;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number))
            return Math.Max(0, number);
        if (value.ValueKind == JsonValueKind.String &&
            long.TryParse(value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out number))
            return Math.Max(0, number);
        return 0;
    }

    public static decimal Decimal(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value))
            return 0;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDecimal(out var number))
            return Math.Max(0, number);
        if (value.ValueKind == JsonValueKind.String &&
            decimal.TryParse(value.GetString(), NumberStyles.Number, CultureInfo.InvariantCulture, out number))
            return Math.Max(0, number);
        return 0;
    }

    public static DateTimeOffset? Timestamp(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value))
            return null;
        if (value.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(
                value.GetString(),
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal,
                out var timestamp))
            return timestamp;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var epoch))
            return epoch > 10_000_000_000
                ? DateTimeOffset.FromUnixTimeMilliseconds(epoch)
                : DateTimeOffset.FromUnixTimeSeconds(epoch);
        return null;
    }

    public static TokenUsage StandardTokens(JsonElement tokens) => new(
        Int64(tokens, "input"),
        Int64(tokens, "output"),
        Int64(tokens, "cacheRead"),
        Int64(tokens, "cacheWrite"),
        Int64(tokens, "reasoning"));
}
