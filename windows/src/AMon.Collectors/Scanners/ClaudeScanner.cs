using System.Text.Json;
using AMon.Core;

namespace AMon.Collectors.Scanners;

public sealed class ClaudeScanner : IUsageScanner
{
    private readonly string _root;
    private readonly IncrementalFileCache<ClaudeFileContribution> _cache = new();

    public ClaudeScanner()
        : this(ResolveDefaultRoot())
    {
    }

    public ClaudeScanner(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        _root = Path.GetFullPath(Environment.ExpandEnvironmentVariables(root.Trim()));
    }

    public string Tool => "claudeCode";

    internal int CachedFileParseCount => _cache.ParseCount;

    public async Task<ToolSummary> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(_root))
        {
            return new ScannerResultBuilder(Tool, "Claude Code", false, context)
                .Build(0, null, "경로를 찾을 수 없습니다", scanSucceeded: false);
        }

        var files = EnumerateJsonlFiles(_root);
        var cachedFiles = await _cache.ResolveAsync(
            files,
            static (path, cancellationToken) =>
                ValueTask.FromResult(ParseFile(path, cancellationToken)),
            cancellationToken);
        var sessionNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var seenGlobal = new HashSet<string>(StringComparer.Ordinal);
        var messages = new List<ClaudeMessage>();
        DateTimeOffset? lastActivity = null;

        foreach (var cachedFile in cachedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            sessionNames.Add(Path.GetFileNameWithoutExtension(cachedFile.Path));
            lastActivity = Latest(lastActivity, cachedFile.Fingerprint.LastWriteTime);
            foreach (var keyedMessage in cachedFile.Value.Messages)
            {
                if (seenGlobal.Add(keyedMessage.Key))
                {
                    messages.Add(keyedMessage.Message);
                }
            }
        }

        var builder = new ScannerResultBuilder(Tool, "Claude Code", true, context);
        foreach (var message in messages)
        {
            builder.Add(
                message.Usage,
                message.Timestamp,
                message.Model,
                includeModelTotal: !string.Equals(
                    message.Model,
                    "<synthetic>",
                    StringComparison.Ordinal));
        }

        return builder.Build(
            sessionNames.Count,
            lastActivity,
            sessionNames.Count == 0 ? "세션 로그가 없습니다" : null);
    }

    private static ClaudeFileContribution ParseFile(
        string path,
        CancellationToken cancellationToken)
    {
        var byMessage = new Dictionary<string, ClaudeMessage>(StringComparer.Ordinal);
        var messageOrder = new List<string>();
        var lineNumber = 0L;
        foreach (var line in SharedFile.ReadLines(path))
        {
            cancellationToken.ThrowIfCancellationRequested();
            lineNumber++;
            if (!line.Contains("\"usage\"", StringComparison.Ordinal) ||
                !TryParseMessage(line, path, lineNumber, out var key, out var message))
            {
                continue;
            }

            if (!byMessage.ContainsKey(key))
                messageOrder.Add(key);
            byMessage[key] = message;
        }

        return new ClaudeFileContribution(
            messageOrder
                .Select(key => new ClaudeKeyedMessage(key, byMessage[key]))
                .ToArray());
    }

    private static bool TryParseMessage(
        string line,
        string path,
        long lineNumber,
        out string key,
        out ClaudeMessage message)
    {
        key = string.Empty;
        message = default;

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("type", out var type) ||
                !string.Equals(type.GetString(), "assistant", StringComparison.Ordinal) ||
                !root.TryGetProperty("message", out var messageElement) ||
                !messageElement.TryGetProperty("usage", out var usageElement) ||
                usageElement.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            var messageId = messageElement.TryGetProperty("id", out var id)
                ? id.GetString()
                : null;
            var requestId = root.TryGetProperty("requestId", out var request)
                ? request.GetString()
                : null;
            key = string.IsNullOrEmpty(messageId)
                ? $"{path}\0{lineNumber}"
                : $"{messageId}\0{requestId ?? string.Empty}";

            var usage = new TokenUsage(
                JsonUsage.Int64(usageElement, "input_tokens"),
                JsonUsage.Int64(usageElement, "output_tokens"),
                JsonUsage.Int64(usageElement, "cache_read_input_tokens"),
                JsonUsage.Int64(usageElement, "cache_creation_input_tokens"));
            var model = messageElement.TryGetProperty("model", out var modelElement)
                ? modelElement.GetString()
                : null;

            message = new ClaudeMessage(
                usage,
                JsonUsage.Timestamp(root, "timestamp"),
                model);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static IReadOnlyList<string> EnumerateJsonlFiles(string root)
    {
        try
        {
            return Directory
                .EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories)
                .Where(static path => !Path.GetFileName(path).StartsWith('.'))
                .OrderBy(static path => path, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
        catch (IOException)
        {
            return [];
        }
        catch (UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static DateTimeOffset Latest(DateTimeOffset? current, DateTimeOffset value) =>
        current is null || value > current ? value : current.Value;

    private static string ResolveDefaultRoot()
    {
        var configured = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        var baseDirectory = string.IsNullOrWhiteSpace(configured)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".claude")
            : Environment.ExpandEnvironmentVariables(configured.Trim());
        return Path.Combine(baseDirectory, "projects");
    }

    private readonly record struct ClaudeMessage(
        TokenUsage Usage,
        DateTimeOffset? Timestamp,
        string? Model);

    private readonly record struct ClaudeKeyedMessage(
        string Key,
        ClaudeMessage Message);

    private sealed record ClaudeFileContribution(
        IReadOnlyList<ClaudeKeyedMessage> Messages);
}
