using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using AMon.Core;

namespace AMon.Collectors.Scanners;

internal sealed record CursorCsvEvent(
    DateTimeOffset Timestamp,
    string? Model,
    TokenUsage Usage,
    decimal CostUsd);

internal sealed record CursorCsvResult(IReadOnlyList<CursorCsvEvent> Events);

internal sealed class CursorUsageEventsClient(HttpClient httpClient)
{
    private static readonly Uri ExportEndpoint =
        new("https://cursor.com/api/dashboard/export-usage-events-csv");

    public async Task<CursorCsvResult?> FetchAsync(
        string accessToken,
        UsageScanContext context,
        CancellationToken cancellationToken)
    {
        var userId = TryReadUserId(accessToken);
        if (string.IsNullOrWhiteSpace(userId))
            return null;

        var start = LocalMidnight(context.WindowStart, context.TimeZone);
        var query = string.Create(
            CultureInfo.InvariantCulture,
            $"?startDate={start.ToUnixTimeMilliseconds()}&endDate={context.Now.ToUnixTimeMilliseconds()}&strategy=tokens");
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(ExportEndpoint + query));
        request.Headers.Accept.ParseAdd("text/csv");
        request.Headers.TryAddWithoutValidation(
            "Cookie",
            $"WorkosCursorSessionToken={Uri.EscapeDataString($"{userId}::{accessToken}")}");

        try
        {
            using var response = await httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            if (response.StatusCode != HttpStatusCode.OK)
                return null;

            var csv = await response.Content.ReadAsStringAsync(cancellationToken);
            return Parse(csv, context);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (HttpRequestException)
        {
            return null;
        }
    }

    private static CursorCsvResult? Parse(string csv, UsageScanContext context)
    {
        var records = ParseRecords(csv);
        if (records.Count == 0)
            return null;

        var columns = records[0]
            .Select((name, index) => (Name: name.Trim(), Index: index))
            .GroupBy(static pair => pair.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(static group => group.Key, static group => group.First().Index, StringComparer.OrdinalIgnoreCase);
        if (!columns.TryGetValue("Date", out var dateColumn) ||
            !columns.TryGetValue("Output Tokens", out var outputColumn))
            return null;

        columns.TryGetValue("Model", out var modelColumn);
        var hasModel = columns.ContainsKey("Model");
        columns.TryGetValue("Input (w/ Cache Write)", out var cacheWriteColumn);
        var hasCacheWrite = columns.ContainsKey("Input (w/ Cache Write)");
        columns.TryGetValue("Input (w/o Cache Write)", out var inputColumn);
        var hasInput = columns.ContainsKey("Input (w/o Cache Write)");
        columns.TryGetValue("Cache Read", out var cacheReadColumn);
        var hasCacheRead = columns.ContainsKey("Cache Read");
        columns.TryGetValue("Total Tokens", out var totalColumn);
        var hasTotal = columns.ContainsKey("Total Tokens");
        columns.TryGetValue("Cost", out var costColumn);
        var hasCost = columns.ContainsKey("Cost");

        var events = new List<CursorCsvEvent>();
        foreach (var record in records.Skip(1))
        {
            if (!TryField(record, dateColumn, out var dateText) ||
                !DateTimeOffset.TryParse(
                    dateText,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out var timestamp))
                continue;

            var localDate = context.LocalDate(timestamp);
            if (localDate < context.WindowStart || localDate > context.Today)
                continue;

            var reportedTotal = hasTotal ? Int64At(record, totalColumn) : 0;
            var usage = new TokenUsage(
                hasInput ? Int64At(record, inputColumn) : 0,
                Int64At(record, outputColumn),
                hasCacheRead ? Int64At(record, cacheReadColumn) : 0,
                hasCacheWrite ? Int64At(record, cacheWriteColumn) : 0,
                ReasoningTokens: 0,
                ReportedTotalTokens: reportedTotal > 0 ? reportedTotal : null);
            if (usage.TotalTokens == 0)
                continue;

            var model = hasModel && TryField(record, modelColumn, out var modelText)
                ? modelText.Trim()
                : null;
            var cost = hasCost ? DecimalAt(record, costColumn) : 0;
            events.Add(new CursorCsvEvent(timestamp, model, usage, cost));
        }

        return events.Count == 0 ? null : new CursorCsvResult(events);
    }

    private static List<string[]> ParseRecords(string csv)
    {
        var records = new List<string[]>();
        var record = new List<string>();
        var field = new StringBuilder();
        var quoted = false;

        for (var i = 0; i < csv.Length; i++)
        {
            var character = csv[i];
            if (quoted)
            {
                if (character == '"' && i + 1 < csv.Length && csv[i + 1] == '"')
                {
                    field.Append('"');
                    i++;
                }
                else if (character == '"')
                {
                    quoted = false;
                }
                else
                {
                    field.Append(character);
                }
                continue;
            }

            switch (character)
            {
                case '"' when field.Length == 0:
                    quoted = true;
                    break;
                case ',':
                    record.Add(field.ToString());
                    field.Clear();
                    break;
                case '\r':
                    break;
                case '\n':
                    record.Add(field.ToString());
                    field.Clear();
                    if (record.Any(static value => value.Length > 0))
                        records.Add(record.ToArray());
                    record.Clear();
                    break;
                default:
                    field.Append(character);
                    break;
            }
        }

        if (field.Length > 0 || record.Count > 0)
        {
            record.Add(field.ToString());
            if (record.Any(static value => value.Length > 0))
                records.Add(record.ToArray());
        }
        return records;
    }

    private static DateTimeOffset LocalMidnight(DateOnly date, TimeZoneInfo timeZone)
    {
        var local = date.ToDateTime(TimeOnly.MinValue, DateTimeKind.Unspecified);
        return new DateTimeOffset(local, timeZone.GetUtcOffset(local));
    }

    private static string? TryReadUserId(string token)
    {
        var parts = token.Split('.');
        if (parts.Length < 2)
            return null;
        try
        {
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + ((4 - payload.Length % 4) % 4), '=');
            using var document = JsonDocument.Parse(Convert.FromBase64String(payload));
            if (!document.RootElement.TryGetProperty("sub", out var subject))
                return null;
            var value = subject.GetString();
            if (string.IsNullOrWhiteSpace(value))
                return null;
            var separator = value.IndexOf('|');
            return separator >= 0 ? value[(separator + 1)..] : value;
        }
        catch (Exception exception) when (
            exception is FormatException or JsonException)
        {
            return null;
        }
    }

    private static bool TryField(IReadOnlyList<string> record, int index, out string value)
    {
        if (index >= 0 && index < record.Count)
        {
            value = record[index];
            return true;
        }
        value = string.Empty;
        return false;
    }

    private static long Int64At(IReadOnlyList<string> record, int index) =>
        TryField(record, index, out var value) &&
        long.TryParse(value.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var result)
            ? Math.Max(0, result)
            : 0;

    private static decimal DecimalAt(IReadOnlyList<string> record, int index) =>
        TryField(record, index, out var value) &&
        decimal.TryParse(value.Trim(), NumberStyles.Number, CultureInfo.InvariantCulture, out var result)
            ? Math.Max(0, result)
            : 0;
}
