using System.Text.Json;
using AMon.Core;

namespace AMon.Collectors.Scanners;

public sealed class CodexScanner : IUsageScanner
{
    private readonly string _root;
    private readonly IncrementalFileCache<CodexFileResult> _cache = new();

    public CodexScanner()
        : this(ResolveDefaultRoot())
    {
    }

    public CodexScanner(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        _root = Path.GetFullPath(Environment.ExpandEnvironmentVariables(root.Trim()));
    }

    public string Tool => "codex";

    internal int CachedFileParseCount => _cache.ParseCount;

    public async Task<ToolSummary> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(_root))
        {
            return new ScannerResultBuilder(Tool, "Codex CLI", false, context)
                .Build(0, null, "경로를 찾을 수 없습니다", scanSucceeded: false);
        }

        var builder = new ScannerResultBuilder(Tool, "Codex CLI", true, context);
        var sessions = 0L;
        DateTimeOffset? lastActivity = null;

        var cachedFiles = await _cache.ResolveAsync(
            EnumerateJsonlFiles(_root),
            static (path, cancellationToken) =>
                ValueTask.FromResult(ParseFile(path, cancellationToken)),
            cancellationToken);
        foreach (var cachedFile in cachedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var contribution = cachedFile.Value.Contribution;
            if (contribution is null)
            {
                continue;
            }

            sessions++;
            lastActivity = Latest(lastActivity, cachedFile.Fingerprint.LastWriteTime);
            builder.AddTotal(contribution.SessionUsage, contribution.FinalModel);

            var factor = contribution.TurnTotal > 0 && contribution.AuthoritativeTotal > 0
                ? (double)contribution.AuthoritativeTotal / contribution.TurnTotal
                : 1d;
            foreach (var turn in contribution.Turns)
            {
                if (turn.Timestamp is null)
                {
                    continue;
                }

                var scaled = IsApproximatelyOne(factor)
                    ? turn.Usage
                    : ScaleUsage(turn.Usage, factor);
                var targetTotal = IsApproximatelyOne(factor)
                    ? turn.AuthoritativeTotal
                    : checked((long)Math.Round(
                        turn.AuthoritativeTotal * factor,
                        MidpointRounding.AwayFromZero));
                var usage = NormalizeToAuthoritativeTotal(scaled, targetTotal);
                builder.AddDaily(usage, turn.Timestamp.Value, turn.Model);
            }
        }

        return builder.Build(
            sessions,
            lastActivity,
            sessions == 0 ? "토큰 기록이 있는 세션이 없습니다" : null);
    }

    private static CodexFileResult ParseFile(
        string path,
        CancellationToken cancellationToken)
    {
        CodexSnapshot? finalSnapshot = null;
        var currentModel = "unknown";
        var turns = new List<ParsedTurn>();
        long turnTotal = 0;

        foreach (var line in SharedFile.ReadLines(path))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (line.Contains("\"turn_context\"", StringComparison.Ordinal))
            {
                currentModel = ParseTurnContextModel(line) ?? currentModel;
                continue;
            }

            if (!line.Contains("\"token_count\"", StringComparison.Ordinal))
            {
                continue;
            }

            if (!TryParseTokenCount(line, currentModel, out var snapshot, out var turn))
            {
                continue;
            }

            if (snapshot is not null)
            {
                finalSnapshot = snapshot;
            }

            if (turn is not null)
            {
                turnTotal = checked(turnTotal + turn.Value.AuthoritativeTotal);
                turns.Add(turn.Value);
            }
        }

        if (finalSnapshot is null)
        {
            return new CodexFileResult(null);
        }

        var sessionUsage = NormalizeToAuthoritativeTotal(
            finalSnapshot.Value.Usage,
            finalSnapshot.Value.AuthoritativeTotal);
        return new CodexFileResult(
            new CodexContribution(
                sessionUsage,
                finalSnapshot.Value.AuthoritativeTotal,
                currentModel,
                turnTotal,
                turns));
    }

    private static bool TryParseTokenCount(
        string line,
        string model,
        out CodexSnapshot? snapshot,
        out ParsedTurn? turn)
    {
        snapshot = null;
        turn = null;

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("payload", out var payload) ||
                !payload.TryGetProperty("type", out var type) ||
                !string.Equals(type.GetString(), "token_count", StringComparison.Ordinal) ||
                !payload.TryGetProperty("info", out var info) ||
                info.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            if (info.TryGetProperty("total_token_usage", out var totalElement) &&
                totalElement.ValueKind == JsonValueKind.Object)
            {
                snapshot = ParseUsage(totalElement);
            }

            if (info.TryGetProperty("last_token_usage", out var lastElement) &&
                lastElement.ValueKind == JsonValueKind.Object)
            {
                var parsed = ParseUsage(lastElement);
                turn = new ParsedTurn(
                    parsed.Usage,
                    JsonUsage.Timestamp(root, "timestamp"),
                    model,
                    parsed.AuthoritativeTotal);
            }

            return snapshot is not null || turn is not null;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static CodexSnapshot ParseUsage(JsonElement element)
    {
        var rawInput = JsonUsage.Int64(element, "input_tokens");
        var cacheRead = JsonUsage.Int64(element, "cached_input_tokens");
        var output = JsonUsage.Int64(element, "output_tokens");
        var reasoning = JsonUsage.Int64(element, "reasoning_output_tokens");
        var authoritativeTotal = JsonUsage.Int64(element, "total_tokens");
        if (authoritativeTotal == 0)
        {
            authoritativeTotal = checked(rawInput + output);
        }

        return new CodexSnapshot(
            new TokenUsage(
                Math.Max(0, rawInput - cacheRead),
                output,
                cacheRead,
                ReasoningTokens: reasoning),
            authoritativeTotal);
    }

    private static string? ParseTurnContextModel(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("payload", out var payload) ||
                !payload.TryGetProperty("type", out var type) ||
                !string.Equals(type.GetString(), "turn_context", StringComparison.Ordinal) ||
                !payload.TryGetProperty("model", out var model))
            {
                return null;
            }

            return string.IsNullOrWhiteSpace(model.GetString()) ? null : model.GetString();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static TokenUsage ScaleUsage(TokenUsage usage, double factor)
    {
        static long Scale(long value, double scale) =>
            checked((long)Math.Round(value * scale, MidpointRounding.AwayFromZero));

        return new TokenUsage(
            Scale(usage.InputTokens, factor),
            Scale(usage.OutputTokens, factor),
            Scale(usage.CacheReadTokens, factor),
            Scale(usage.CacheWriteTokens, factor),
            Scale(usage.ReasoningTokens, factor));
    }

    private static TokenUsage NormalizeToAuthoritativeTotal(TokenUsage usage, long target)
    {
        if (target <= 0 || usage.TotalTokens == target || usage.TotalTokens == 0)
        {
            return usage;
        }

        var scaled = ScaleUsage(usage, (double)target / usage.TotalTokens);
        var difference = target - scaled.TotalTokens;
        return scaled with
        {
            InputTokens = checked(Math.Max(0, scaled.InputTokens + difference)),
        };
    }

    private static bool IsApproximatelyOne(double value) =>
        value is >= 0.9999 and <= 1.0001;

    private static IReadOnlyList<string> EnumerateJsonlFiles(string root)
    {
        try
        {
            return Directory
                .EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories)
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
        var configured = Environment.GetEnvironmentVariable("CODEX_HOME");
        var baseDirectory = string.IsNullOrWhiteSpace(configured)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".codex")
            : Environment.ExpandEnvironmentVariables(configured.Trim());
        return Path.Combine(baseDirectory, "sessions");
    }

    private readonly record struct CodexSnapshot(
        TokenUsage Usage,
        long AuthoritativeTotal);

    private readonly record struct ParsedTurn(
        TokenUsage Usage,
        DateTimeOffset? Timestamp,
        string Model,
        long AuthoritativeTotal);

    private sealed record CodexContribution(
        TokenUsage SessionUsage,
        long AuthoritativeTotal,
        string FinalModel,
        long TurnTotal,
        IReadOnlyList<ParsedTurn> Turns);

    private sealed record CodexFileResult(CodexContribution? Contribution);
}
