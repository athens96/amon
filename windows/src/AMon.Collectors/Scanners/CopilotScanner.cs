using System.Text.Json;
using AMon.Core;

namespace AMon.Collectors.Scanners;

public sealed class CopilotScanner : IUsageScanner
{
    private readonly string _root;
    private readonly IncrementalFileCache<ParsedFileContribution> _cache = new();

    public CopilotScanner()
        : this(ResolveDefaultRoot())
    {
    }

    public CopilotScanner(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        _root = Path.GetFullPath(Environment.ExpandEnvironmentVariables(root.Trim()));
    }

    public string Tool => "copilot";

    internal int CachedFileParseCount => _cache.ParseCount;

    public async Task<ToolSummary> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(_root))
            return new ScannerResultBuilder(Tool, "Copilot CLI", false, context)
                .Build(0, null, "경로를 찾을 수 없습니다", scanSucceeded: false);

        var selected = SelectSessionFiles(_root);
        var builder = new ScannerResultBuilder(Tool, "Copilot CLI", true, context);
        DateTimeOffset? lastActivity = null;
        var cachedFiles = await _cache.ResolveAsync(
            selected.OrderBy(static pair => pair.Key, StringComparer.OrdinalIgnoreCase)
                .Select(static pair => pair.Value),
            static (path, cancellationToken) =>
                new ValueTask<ParsedFileContribution>(ParseFileAsync(path, cancellationToken)),
            cancellationToken);
        foreach (var cachedFile in cachedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            cachedFile.Value.Apply(builder);
            var modified = cachedFile.Fingerprint.LastWriteTime;
            if (lastActivity is null || modified > lastActivity)
                lastActivity = modified;
        }

        return builder.Build(
            selected.Count,
            lastActivity,
            selected.Count == 0 ? "세션 로그가 없습니다" : null);
    }

    private static async Task<ParsedFileContribution> ParseFileAsync(
        string path,
        CancellationToken cancellationToken)
    {
        var entries = new List<ParsedUsageEntry>();
        await using var stream = SharedFile.OpenRead(path);
        using var reader = new StreamReader(stream);
        while (await reader.ReadLineAsync(cancellationToken) is { } line)
        {
            if (!line.Contains("\"session.shutdown\"", StringComparison.Ordinal))
                continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (String(root, "type") != "session.shutdown"
                    || !root.TryGetProperty("data", out var data)
                    || !data.TryGetProperty("modelMetrics", out var metrics)
                    || metrics.ValueKind != JsonValueKind.Object)
                    continue;

                var timestamp = JsonUsage.Timestamp(root, "timestamp");
                foreach (var model in metrics.EnumerateObject())
                {
                    if (!model.Value.TryGetProperty("usage", out var usage)
                        || usage.ValueKind != JsonValueKind.Object)
                        continue;
                    var read = JsonUsage.Int64(usage, "cacheReadTokens");
                    var write = JsonUsage.Int64(usage, "cacheWriteTokens");
                    var tokens = new TokenUsage(
                        Math.Max(0, JsonUsage.Int64(usage, "inputTokens") - read - write),
                        JsonUsage.Int64(usage, "outputTokens"),
                        read,
                        write,
                        JsonUsage.Int64(usage, "reasoningTokens"));
                    if (tokens.TotalTokens > 0)
                    {
                        entries.Add(new ParsedUsageEntry(
                            tokens,
                            timestamp,
                            NormalizeModel(model.Name)));
                    }
                }
            }
            catch (JsonException)
            {
                // Ignore a partial JSONL tail.
            }
        }

        return new ParsedFileContribution(
            entries,
            [SessionIdForPath(path)]);
    }

    private static string SessionIdForPath(string path) =>
        string.Equals(Path.GetFileName(path), "events.jsonl", StringComparison.OrdinalIgnoreCase)
            ? Path.GetFileName(Path.GetDirectoryName(path)) ?? string.Empty
            : Path.GetFileNameWithoutExtension(path);

    private static Dictionary<string, string> SelectSessionFiles(string root)
    {
        var selected = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var directorySessions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            var eventsPath = Path.Combine(directory, "events.jsonl");
            if (!File.Exists(eventsPath))
                continue;
            var id = Path.GetFileName(directory);
            directorySessions.Add(id);
            selected[id] = eventsPath;
        }
        foreach (var path in Directory.EnumerateFiles(root, "*.jsonl", SearchOption.TopDirectoryOnly))
        {
            var id = Path.GetFileNameWithoutExtension(path);
            if (!directorySessions.Contains(id))
                selected[id] = path;
        }
        return selected;
    }

    private static string NormalizeModel(string model) =>
        model.StartsWith("claude-", StringComparison.Ordinal)
            ? model.Replace('.', '-')
            : model;

    private static string? String(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static string ResolveDefaultRoot()
    {
        var configured = Environment.GetEnvironmentVariable("COPILOT_DIR");
        var baseDirectory = string.IsNullOrWhiteSpace(configured)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".copilot")
            : Environment.ExpandEnvironmentVariables(configured.Trim());
        return Path.Combine(baseDirectory, "session-state");
    }
}
