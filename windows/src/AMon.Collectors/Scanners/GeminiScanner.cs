using System.Text.Json;
using AMon.Core;

namespace AMon.Collectors.Scanners;

public sealed class GeminiScanner : IUsageScanner
{
    private readonly string _root;
    private readonly IncrementalFileCache<GeminiFile> _cache = new();

    public GeminiScanner()
        : this(ResolveDefaultRoot())
    {
    }

    public GeminiScanner(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        _root = Path.GetFullPath(Environment.ExpandEnvironmentVariables(root.Trim()));
    }

    public string Tool => "gemini";

    internal int CachedFileParseCount => _cache.ParseCount;

    public async Task<ToolSummary> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(_root))
            return new ScannerResultBuilder(Tool, "Gemini CLI", false, context)
                .Build(0, null, "경로를 찾을 수 없습니다", scanSucceeded: false);

        var builder = new ScannerResultBuilder(Tool, "Gemini CLI", true, context);
        var sessions = new HashSet<string>(StringComparer.Ordinal);
        DateTimeOffset? lastActivity = null;

        var paths = Directory.EnumerateFiles(_root, "session-*", SearchOption.AllDirectories)
            .Where(static path =>
                path.EndsWith(".json", StringComparison.OrdinalIgnoreCase)
                || path.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase))
            .OrderBy(static path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var cachedFiles = await _cache.ResolveAsync(
            paths,
            static (path, cancellationToken) =>
                new ValueTask<GeminiFile>(ParseFileAsync(path, cancellationToken)),
            cancellationToken);
        foreach (var cachedFile in cachedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var parsed = cachedFile.Value;
            sessions.Add(parsed.SessionId);
            ApplyMessages(builder, parsed.Messages);

            var modified = cachedFile.Fingerprint.LastWriteTime;
            if (lastActivity is null || modified > lastActivity)
                lastActivity = modified;
        }

        return builder.Build(
            sessions.Count,
            lastActivity,
            sessions.Count == 0 ? "세션 로그가 없습니다" : null);
    }

    private static async Task<GeminiFile> ParseFileAsync(
        string path,
        CancellationToken cancellationToken)
    {
        var fallback = Path.GetFileNameWithoutExtension(path);
        var text = await SharedFile.ReadAllTextAsync(path, cancellationToken);
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty("messages", out var messages)
                && messages.ValueKind == JsonValueKind.Array)
            {
                var sessionId = String(root, "sessionId") ?? fallback;
                return new GeminiFile(
                    sessionId,
                    messages.EnumerateArray().Select(ParseMessage).ToArray());
            }
        }
        catch (JsonException exception) when (
            path.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "Gemini session JSON is incomplete or malformed.",
                exception);
        }
        catch (JsonException)
        {
            // JSONL is intentionally not one valid JSON document.
        }

        var session = fallback;
        var ordered = new List<GeminiMessage>();
        var positions = new Dictionary<string, int>(StringComparer.Ordinal);
        using var reader = new StringReader(text);
        while (await reader.ReadLineAsync(cancellationToken) is { } line)
        {
            if (string.IsNullOrWhiteSpace(line))
                continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                var element = document.RootElement;
                session = String(element, "sessionId") ?? session;
                var message = ParseMessage(element);
                if (message.Type is not ("user" or "gemini"))
                    continue;
                if (!string.IsNullOrEmpty(message.Id)
                    && positions.TryGetValue(message.Id, out var position))
                {
                    ordered[position] = message;
                }
                else
                {
                    if (!string.IsNullOrEmpty(message.Id))
                        positions[message.Id] = ordered.Count;
                    ordered.Add(message);
                }
            }
            catch (JsonException)
            {
                // A partially-written line must not discard the rest of the session.
            }
        }
        return new GeminiFile(session, ordered);
    }

    private static void ApplyMessages(
        ScannerResultBuilder builder,
        IEnumerable<GeminiMessage> messages)
    {
        long previousInput = 0;
        long previousCached = 0;
        foreach (var message in messages)
        {
            if (message.Type != "gemini" || message.Tokens is null)
                continue;

            var tokens = message.Tokens.Value;
            var input = tokens.Input - previousInput;
            if (input < 0) input = tokens.Input;
            var cached = tokens.Cached - previousCached;
            if (cached < 0) cached = tokens.Cached;
            previousInput = tokens.Input;
            previousCached = tokens.Cached;

            var usage = new TokenUsage(
                input,
                checked(tokens.Output + tokens.Thoughts),
                cached,
                ReasoningTokens: tokens.Thoughts);
            if (usage.TotalTokens > 0)
                builder.Add(usage, message.Timestamp, message.Model);
        }
    }

    private static GeminiMessage ParseMessage(JsonElement element)
    {
        GeminiTokens? tokens = null;
        if (element.TryGetProperty("tokens", out var value)
            && value.ValueKind == JsonValueKind.Object)
        {
            tokens = new GeminiTokens(
                JsonUsage.Int64(value, "input"),
                JsonUsage.Int64(value, "output"),
                JsonUsage.Int64(value, "cached"),
                JsonUsage.Int64(value, "thoughts"));
        }
        return new GeminiMessage(
            String(element, "id"),
            String(element, "type"),
            String(element, "model"),
            JsonUsage.Timestamp(element, "timestamp"),
            tokens);
    }

    private static string? String(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static string ResolveDefaultRoot()
    {
        var configured = Environment.GetEnvironmentVariable("GEMINI_DIR");
        var baseDirectory = string.IsNullOrWhiteSpace(configured)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".gemini")
            : Environment.ExpandEnvironmentVariables(configured.Trim());
        return Path.Combine(baseDirectory, "tmp");
    }

    private sealed record GeminiFile(string SessionId, IReadOnlyList<GeminiMessage> Messages);
    private sealed record GeminiMessage(
        string? Id,
        string? Type,
        string? Model,
        DateTimeOffset? Timestamp,
        GeminiTokens? Tokens);
    private readonly record struct GeminiTokens(long Input, long Output, long Cached, long Thoughts);
}
