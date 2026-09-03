using System.Text.Json;
using System.Text.Json.Serialization;

namespace AMon.Core;

/// One Cursor usage event from the dashboard CSV export, kept locally so session token estimates
/// survive an offline restart. Timestamps and totals only — never prompt text.
public sealed record CursorUsageEvent(
    [property: JsonPropertyName("timestamp")] DateTimeOffset Timestamp,
    [property: JsonPropertyName("model")] string? Model,
    [property: JsonPropertyName("input")] long InputTokens,
    [property: JsonPropertyName("output")] long OutputTokens,
    [property: JsonPropertyName("cache_read")] long CacheReadTokens,
    [property: JsonPropertyName("cache_write")] long CacheWriteTokens,
    [property: JsonPropertyName("total")] long? ReportedTotalTokens)
{
    public TokenUsage Usage => new(InputTokens, OutputTokens, CacheReadTokens, CacheWriteTokens, 0, ReportedTotalTokens);
}

/// The scanner writes the latest CSV events here after each successful fetch; the session
/// history reads them back to estimate per-composer tokens. Ported from the macOS
/// `CursorSessionTokens` disk cache (`cache/cursor-events.json`).
public static class CursorUsageEventCache
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = false };

    public sealed record CacheFile(
        [property: JsonPropertyName("fetched_at")] DateTimeOffset FetchedAt,
        [property: JsonPropertyName("events")] IReadOnlyList<CursorUsageEvent> Events);

    public static string DefaultPath() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "A-mon", "cache", "cursor-events.json");

    public static CacheFile? Load(string path)
    {
        try
        {
            if (!File.Exists(path))
                return null;
            return JsonSerializer.Deserialize<CacheFile>(File.ReadAllText(path), Options);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    /// Best-effort: a failed write only means the next scan re-fetches. Never throws.
    public static void Store(string path, DateTimeOffset fetchedAt, IReadOnlyList<CursorUsageEvent> events)
    {
        try
        {
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
                Directory.CreateDirectory(directory);
            var temporary = Path.Combine(directory ?? string.Empty, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
            try
            {
                File.WriteAllText(temporary, JsonSerializer.Serialize(new CacheFile(fetchedAt, events), Options));
                File.Move(temporary, path, overwrite: true);
            }
            finally
            {
                if (File.Exists(temporary))
                    File.Delete(temporary);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }
}

/// Per-session Cursor token **estimate**. The local database carries no per-session tokens (every
/// bubble `tokenCount` is 0 in current builds), so dashboard usage events are attributed to the
/// composer whose bubble is nearest in time. An estimate can disagree with billing — in
/// particular, usage from the same account on another machine can land on a local session.
///
/// Attribution rule (ported from macOS `CursorSessionTokens.attribute`): the composer with the
/// nearest bubble owns the event; a composer's [createdAt, lastUpdatedAt] window can span days of
/// idle time, so membership is by bubble distance, and an event farther than `MaxGap` from every
/// bubble is attributed to no session.
public static class CursorSessionTokenEstimator
{
    public static readonly TimeSpan MaxGap = TimeSpan.FromMinutes(10);

    public sealed record SessionBubbles(string Id, IReadOnlyList<DateTimeOffset> BubbleTimes);

    public sealed class Estimate
    {
        public TokenUsage Usage { get; internal set; }

        /// Total tokens per model from the CSV's model column — more specific than the composer's "auto".
        public Dictionary<string, long> Models { get; } = new(StringComparer.Ordinal);

        public string? TopModel => Models.Count == 0
            ? null
            : Models.OrderByDescending(static pair => pair.Value).ThenBy(static pair => pair.Key, StringComparer.Ordinal).First().Key;
    }

    public static IReadOnlyDictionary<string, Estimate> Attribute(
        IReadOnlyList<CursorUsageEvent> events,
        IReadOnlyList<SessionBubbles> sessions)
    {
        var estimates = new Dictionary<string, Estimate>(StringComparer.Ordinal);
        var candidates = sessions
            .Where(static session => session.BubbleTimes.Count > 0)
            .Select(static session => (session.Id, Bubbles: session.BubbleTimes.Select(static time => time.ToUnixTimeMilliseconds()).Order().ToArray()))
            .ToArray();
        if (candidates.Length == 0 || events.Count == 0)
            return estimates;

        var maxGapMs = (long)MaxGap.TotalMilliseconds;
        foreach (var usageEvent in events)
        {
            var at = usageEvent.Timestamp.ToUnixTimeMilliseconds();
            string? bestId = null;
            var bestDistance = long.MaxValue;
            foreach (var (id, bubbles) in candidates)
            {
                var distance = NearestDistance(at, bubbles);
                if (distance < bestDistance)
                {
                    bestDistance = distance;
                    bestId = id;
                }
            }
            if (bestId is null || bestDistance > maxGapMs)
                continue;
            if (!estimates.TryGetValue(bestId, out var estimate))
                estimates[bestId] = estimate = new Estimate();
            estimate.Usage = estimate.Usage.Add(usageEvent.Usage);
            if (!string.IsNullOrEmpty(usageEvent.Model))
                estimate.Models[usageEvent.Model] = estimate.Models.GetValueOrDefault(usageEvent.Model) + usageEvent.Usage.TotalTokens;
        }
        return estimates;
    }

    /// Distance from `at` to the nearest element of a sorted array (binary search).
    private static long NearestDistance(long at, long[] sortedBubbles)
    {
        var index = Array.BinarySearch(sortedBubbles, at);
        if (index >= 0)
            return 0;
        index = ~index;
        var best = long.MaxValue;
        if (index < sortedBubbles.Length)
            best = Math.Min(best, Math.Abs(sortedBubbles[index] - at));
        if (index > 0)
            best = Math.Min(best, Math.Abs(sortedBubbles[index - 1] - at));
        return best;
    }
}
