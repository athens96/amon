using System.Globalization;
using System.Text.RegularExpressions;

namespace AMon.Quotas;

/// ISO-8601 and epoch conversions shared by the mappers. Normalizes the timestamp shapes providers
/// return (space separator, ` UTC` suffix, variable fractional digits, no zone) before parsing.
public static partial class QuotaTime
{
    public static DateTimeOffset? ParseIso8601(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return null;
        var text = Normalize(raw.Trim());
        return DateTimeOffset.TryParse(
            text,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out var parsed)
            ? parsed
            : null;
    }

    /// A bare `yyyy-MM-dd` date, read as midnight UTC.
    public static DateTimeOffset? ParseDateOnly(string? raw) =>
        !string.IsNullOrWhiteSpace(raw)
        && DateTime.TryParseExact(
            raw.Trim(),
            "yyyy-MM-dd",
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out var date)
            ? new DateTimeOffset(date, TimeSpan.Zero)
            : null;

    public static DateTimeOffset? FromEpochSeconds(double? seconds) =>
        seconds is { } value ? FromUnixMilliseconds(value * 1000) : null;

    public static DateTimeOffset? FromEpochMilliseconds(double? milliseconds) =>
        milliseconds is { } value ? FromUnixMilliseconds(value) : null;

    /// Providers occasionally send the wrong unit (microseconds for milliseconds, milliseconds for
    /// seconds). An out-of-range instant is "no reset time", never an exception out of a mapper.
    private static DateTimeOffset? FromUnixMilliseconds(double milliseconds)
    {
        if (!double.IsFinite(milliseconds))
            return null;
        const double minMs = -62135596800000d; // 0001-01-01
        const double maxMs = 253402300799999d; // 9999-12-31
        if (milliseconds < minMs || milliseconds > maxMs)
            return null;
        return DateTimeOffset.FromUnixTimeMilliseconds((long)milliseconds);
    }

    public static string ToIso8601(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    private static string Normalize(string raw)
    {
        var text = raw;
        if (SpaceSeparated().IsMatch(text))
            text = string.Concat(text.AsSpan(0, 10), "T", text.AsSpan(11));
        if (text.EndsWith(" UTC", StringComparison.Ordinal))
            text = string.Concat(text.AsSpan(0, text.Length - 4), "Z");
        if (NoZone().IsMatch(text))
            text += "Z";
        return text;
    }

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}")]
    private static partial Regex SpaceSeparated();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?$")]
    private static partial Regex NoZone();
}
