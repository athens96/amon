using System.Text.Json;
using AMon.Core;

namespace AMon.Collectors.Scanners;

public sealed class QwenScanner : IUsageScanner
{
    private readonly string _root;
    private readonly IncrementalFileCache<ParsedFileContribution> _cache = new();

    public QwenScanner()
        : this(ResolveDefaultRoot())
    {
    }

    public QwenScanner(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        _root = Path.GetFullPath(Environment.ExpandEnvironmentVariables(root.Trim()));
    }

    public string Tool => "qwen";

    internal int CachedFileParseCount => _cache.ParseCount;

    public async Task<ToolSummary> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(_root))
            return new ScannerResultBuilder(Tool, "Qwen Code", false, context)
                .Build(0, null, "경로를 찾을 수 없습니다", scanSucceeded: false);

        var builder = new ScannerResultBuilder(Tool, "Qwen Code", true, context);
        var sessions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        DateTimeOffset? lastActivity = null;
        var paths = Directory.EnumerateFiles(_root, "*.jsonl", SearchOption.AllDirectories)
            .Where(static path => !Path.GetFileName(path).StartsWith('.'))
            .OrderBy(static path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var cachedFiles = await _cache.ResolveAsync(
            paths,
            static (path, cancellationToken) =>
                new ValueTask<ParsedFileContribution>(ParseFileAsync(path, cancellationToken)),
            cancellationToken);
        foreach (var cachedFile in cachedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            cachedFile.Value.Apply(builder);
            foreach (var sessionId in cachedFile.Value.SessionIds)
                sessions.Add(sessionId);
            var modified = cachedFile.Fingerprint.LastWriteTime;
            if (lastActivity is null || modified > lastActivity)
                lastActivity = modified;
        }

        return builder.Build(
            sessions.Count,
            lastActivity,
            sessions.Count == 0 ? "세션 로그가 없습니다" : null);
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
            if (!line.Contains("\"usageMetadata\"", StringComparison.Ordinal))
                continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                var element = document.RootElement;
                if (String(element, "type") != "assistant"
                    || !element.TryGetProperty("usageMetadata", out var usage)
                    || usage.ValueKind != JsonValueKind.Object)
                    continue;

                var prompt = JsonUsage.Int64(usage, "promptTokenCount");
                var cached = JsonUsage.Int64(usage, "cachedContentTokenCount");
                var thoughts = JsonUsage.Int64(usage, "thoughtsTokenCount");
                var tokens = new TokenUsage(
                    Math.Max(0, prompt - cached),
                    checked(JsonUsage.Int64(usage, "candidatesTokenCount") + thoughts),
                    cached,
                    ReasoningTokens: thoughts);
                if (tokens.TotalTokens == 0)
                    continue;

                var model = String(element, "model");
                if (string.IsNullOrWhiteSpace(model)
                    && element.TryGetProperty("message", out var message)
                    && message.ValueKind == JsonValueKind.Object)
                    model = String(message, "model");
                entries.Add(new ParsedUsageEntry(
                    tokens,
                    JsonUsage.Timestamp(element, "timestamp"),
                    model));
            }
            catch (JsonException)
            {
                // Ignore a partial JSONL tail.
            }
        }

        return new ParsedFileContribution(
            entries,
            [Path.GetFileNameWithoutExtension(path)]);
    }

    private static string? String(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static string ResolveDefaultRoot()
    {
        var configured = Environment.GetEnvironmentVariable("QWEN_DIR");
        var baseDirectory = string.IsNullOrWhiteSpace(configured)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".qwen")
            : Environment.ExpandEnvironmentVariables(configured.Trim());
        return Path.Combine(baseDirectory, "projects");
    }
}
