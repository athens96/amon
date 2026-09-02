using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AMon.Quotas;

/// Behavior-free JSON chores shared by every provider mapper: lenient property reads, permissive
/// numbers (JSON numbers or numeric strings), and JWT payload decoding.
public static class QuotaJson
{
    /// Parse a top-level object; `null` for an empty body, a parse failure, or a non-object payload.
    public static JsonDocument? ParseObject(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return null;
        try
        {
            var document = JsonDocument.Parse(text);
            if (document.RootElement.ValueKind == JsonValueKind.Object)
                return document;
            document.Dispose();
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static JsonDocument? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return null;
        try
        {
            return JsonDocument.Parse(text);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static bool TryProperty(JsonElement element, string name, out JsonElement value)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out value))
            return true;
        value = default;
        return false;
    }

    public static JsonElement? Property(JsonElement element, string name) =>
        TryProperty(element, name, out var value) ? value : null;

    public static JsonElement? ObjectProperty(JsonElement element, string name) =>
        TryProperty(element, name, out var value) && value.ValueKind == JsonValueKind.Object ? value : null;

    public static JsonElement? ArrayProperty(JsonElement element, string name) =>
        TryProperty(element, name, out var value) && value.ValueKind == JsonValueKind.Array ? value : null;

    /// A trimmed, non-empty string property; `null` otherwise.
    public static string? String(JsonElement element, string name)
    {
        if (!TryProperty(element, name, out var value) || value.ValueKind != JsonValueKind.String)
            return null;
        var text = value.GetString()?.Trim();
        return string.IsNullOrEmpty(text) ? null : text;
    }

    public static string? FirstString(JsonElement element, params string[] names)
    {
        foreach (var name in names)
        {
            if (String(element, name) is { } value)
                return value;
        }
        return null;
    }

    /// Permissive numeric read: JSON numbers and numeric strings; non-finite values are `null`.
    public static double? Number(JsonElement element, string name) =>
        TryProperty(element, name, out var value) ? Number(value) : null;

    public static double? Number(JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Number when value.TryGetDouble(out var number) && double.IsFinite(number):
                return number;
            case JsonValueKind.String when double.TryParse(
                value.GetString()?.Trim(),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var parsed) && double.IsFinite(parsed):
                return parsed;
            default:
                return null;
        }
    }

    public static bool? Bool(JsonElement element, string name) =>
        TryProperty(element, name, out var value) ? Bool(value) : null;

    public static bool? Bool(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Number when value.TryGetDouble(out var number) => number != 0,
        JsonValueKind.String => value.GetString()?.Trim().ToLowerInvariant() switch
        {
            "true" or "1" => true,
            "false" or "0" => false,
            _ => null,
        },
        _ => null,
    };

    /// Clamp a percentage into 0…100, treating non-finite input as 0.
    public static double ClampPercent(double value) =>
        double.IsFinite(value) ? Math.Clamp(value, 0, 100) : 0;

    /// Decode a JWT's payload (middle segment) as an object; `null` when it isn't a decodable JWT.
    public static JsonDocument? JwtPayload(string token)
    {
        var parts = token.Split('.');
        if (parts.Length < 2)
            return null;
        var payload = parts[1].Replace('-', '+').Replace('_', '/');
        while (payload.Length % 4 != 0)
            payload += "=";
        try
        {
            return ParseObject(Encoding.UTF8.GetString(Convert.FromBase64String(payload)));
        }
        catch (FormatException)
        {
            return null;
        }
    }

    public static string Serialize<T>(T value) =>
        JsonSerializer.Serialize(value, SerializerOptions);

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = false,
    };
}
