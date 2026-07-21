using Microsoft.Data.Sqlite;
using System.Text.Json;

namespace AMon;

public sealed class LocalUsageScanner
{
    private sealed record UsageEvent(DateTimeOffset Timestamp, string Model, TokenUsage Usage, double Cost = 0, string Key = "");
    private sealed record FileResult(long Length, DateTime LastWriteUtc, string SessionId, TokenUsage Total, string Model, List<UsageEvent> Events);

    private readonly Dictionary<string, FileResult> _cache = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _cacheLock = new();
    private static readonly JsonDocumentOptions JsonOptions = new() { AllowTrailingCommas = true };

    public Task<IReadOnlyList<ToolSummary>> ScanAllAsync(ToolPaths paths, CancellationToken cancellationToken = default) =>
        Task.Run<IReadOnlyList<ToolSummary>>(() =>
        {
            var start = new DateTimeOffset(DateTime.Today.AddDays(-29), TimeZoneInfo.Local.GetUtcOffset(DateTime.Today));
            var summaries = new List<ToolSummary>
            {
                ScanClaude(paths.Claude, start),
                ScanCodex(paths.Codex, start),
                ScanOpenCode(paths.OpenCode, start),
                ScanCursor(paths.Cursor, start),
                ScanGemini(paths.Gemini, start),
                ScanQwen(paths.Qwen, start),
                ScanCopilot(paths.Copilot, start)
            };
            foreach (var summary in summaries)
                summary.Today = summary.Daily.GetValueOrDefault(DateTime.Today.ToString("yyyy-MM-dd"))?.Clone() ?? new TokenUsage();
            return summaries;
        }, cancellationToken);

    private ToolSummary ScanClaude(string root, DateTimeOffset start)
    {
        var summary = NewSummary("claudeCode", "Claude Code", root, true);
        if (!summary.PathExists) return summary;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var path in SafeFiles(root, "*.jsonl"))
        {
            var result = Cached(path, ParseClaudeFile);
            if (result is null) continue;
            summary.Sessions++;
            SetLatest(summary, File.GetLastWriteTimeUtc(path));
            foreach (var item in result.Events)
            {
                if (item.Key.Length > 0 && !seen.Add(item.Key)) continue;
                Add(summary, item, start);
            }
        }
        if (summary.Sessions == 0) summary.Note = "세션 로그가 없습니다";
        return summary;
    }

    private FileResult? ParseClaudeFile(string path)
    {
        var messages = new Dictionary<string, UsageEvent>(StringComparer.Ordinal);
        var order = new List<string>();
        var anonymous = 0;
        foreach (var line in ReadLines(path))
        {
            if (!line.Contains("\"usage\"", StringComparison.Ordinal)) continue;
            if (!TryJson(line, out var doc)) continue;
            using (doc)
            {
                var root = doc.RootElement;
                if (Text(root, "type") != "assistant" || !TryObject(root, "message", out var message) || !TryObject(message, "usage", out var usage)) continue;
                var id = Text(message, "id");
                var key = id.Length > 0 ? id + "|" + Text(root, "requestId") : $"__anon__{++anonymous}";
                var input = Long(usage, "input_tokens");
                var output = Long(usage, "output_tokens");
                var cacheWrite = Long(usage, "cache_creation_input_tokens");
                var cacheRead = Long(usage, "cache_read_input_tokens");
                var value = new UsageEvent(ParseTime(Text(root, "timestamp")), Text(message, "model"), new TokenUsage
                {
                    Input = input, Output = output, CacheRead = cacheRead, CacheWrite = cacheWrite,
                    Total = input + output + cacheRead + cacheWrite
                }, Key: key.StartsWith("__anon__", StringComparison.Ordinal) ? "" : key);
                if (!messages.ContainsKey(key)) order.Add(key);
                messages[key] = value;
            }
        }
        return BuildFileResult(path, order.Select(key => messages[key]));
    }

    private ToolSummary ScanCodex(string root, DateTimeOffset start)
    {
        var summary = NewSummary("codex", "Codex CLI", root, true);
        if (!summary.PathExists) return summary;
        var seenNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in SafeFiles(root, "*.jsonl"))
        {
            if (!seenNames.Add(Path.GetFileName(path))) continue;
            var result = Cached(path, ParseCodexFile);
            if (result is null || result.Total.Total == 0) continue;
            summary.Sessions++;
            summary.Usage.Add(result.Total);
            summary.Models[result.Model] = summary.Models.GetValueOrDefault(result.Model) + result.Total.Total;
            SetLatest(summary, File.GetLastWriteTimeUtc(path));
            foreach (var item in result.Events) AddDaily(summary, item, start);
        }
        if (summary.Sessions == 0) summary.Note = "토큰 기록이 있는 세션이 없습니다";
        return summary;
    }

    private FileResult? ParseCodexFile(string path)
    {
        var model = "unknown";
        JsonElement? lastTotal = null;
        var turns = new List<UsageEvent>();
        foreach (var line in ReadLines(path))
        {
            if (!line.Contains("\"token_count\"", StringComparison.Ordinal) && !line.Contains("\"turn_context\"", StringComparison.Ordinal)) continue;
            if (!TryJson(line, out var doc)) continue;
            using (doc)
            {
                var root = doc.RootElement;
                if (!TryObject(root, "payload", out var payload)) continue;
                var type = Text(payload, "type");
                if (type == "turn_context")
                {
                    var next = Text(payload, "model");
                    if (next.Length > 0) model = next;
                    continue;
                }
                if (type != "token_count" || !TryObject(payload, "info", out var info)) continue;
                if (TryObject(info, "total_token_usage", out var total)) lastTotal = total.Clone();
                if (TryObject(info, "last_token_usage", out var last))
                    turns.Add(new UsageEvent(ParseTime(Text(root, "timestamp")), model, CodexUsage(last)));
            }
        }
        if (lastTotal is null) return EmptyFile(path);
        var session = CodexUsage(lastTotal.Value);
        var sumTurns = turns.Sum(item => item.Usage.Total);
        if (sumTurns > 0 && session.Total > 0)
        {
            var factor = (double)session.Total / sumTurns;
            turns = turns.Select(item => item with { Usage = Scale(item.Usage, factor) }).ToList();
        }
        return new FileResult(new FileInfo(path).Length, File.GetLastWriteTimeUtc(path), Path.GetFileNameWithoutExtension(path), session, model, turns);
    }

    private ToolSummary ScanGemini(string root, DateTimeOffset start)
    {
        var summary = NewSummary("gemini", "Gemini CLI", root, true);
        if (!summary.PathExists) return summary;
        foreach (var path in SafeFiles(root, "session-*.json*"))
        {
            var result = Cached(path, ParseGeminiFile);
            if (result is null) continue;
            summary.Sessions++;
            foreach (var item in result.Events) Add(summary, item, start);
        }
        if (summary.Sessions == 0) summary.Note = "세션 로그가 없습니다";
        return summary;
    }

    private FileResult? ParseGeminiFile(string path)
    {
        var text = SafeReadAll(path);
        if (text is null) return null;
        var messages = new List<JsonElement>();
        var sessionId = Path.GetFileNameWithoutExtension(path);
        if (TryJson(text, out var whole))
        {
            using (whole)
            {
                var root = whole.RootElement;
                sessionId = Text(root, "sessionId") is { Length: > 0 } id ? id : sessionId;
                if (root.TryGetProperty("messages", out var array) && array.ValueKind == JsonValueKind.Array)
                    messages.AddRange(array.EnumerateArray().Select(item => item.Clone()));
            }
        }
        else
        {
            var byId = new Dictionary<string, JsonElement>();
            var order = new List<string>();
            var anon = 0;
            foreach (var line in ReadLines(path))
            {
                if (!TryJson(line, out var doc)) continue;
                using (doc)
                {
                    var root = doc.RootElement;
                    if (Text(root, "sessionId") is { Length: > 0 } id) sessionId = id;
                    if (Text(root, "type") is not ("gemini" or "user")) continue;
                    var key = Text(root, "id");
                    if (key.Length == 0) key = $"anon-{++anon}";
                    if (!byId.ContainsKey(key)) order.Add(key);
                    byId[key] = root.Clone();
                }
            }
            messages.AddRange(order.Select(key => byId[key]));
        }

        long previousInput = 0, previousCached = 0;
        var events = new List<UsageEvent>();
        foreach (var message in messages)
        {
            if (Text(message, "type") != "gemini" || !TryObject(message, "tokens", out var tokens)) continue;
            var cumulativeInput = Long(tokens, "input");
            var cumulativeCached = Long(tokens, "cached");
            var input = cumulativeInput - previousInput;
            var cached = cumulativeCached - previousCached;
            if (input < 0) input = cumulativeInput;
            if (cached < 0) cached = cumulativeCached;
            previousInput = cumulativeInput;
            previousCached = cumulativeCached;
            var thoughts = Long(tokens, "thoughts");
            var output = Long(tokens, "output") + thoughts;
            var usage = new TokenUsage { Input = input, Output = output, CacheRead = cached, Reasoning = thoughts, Total = input + output + cached };
            if (usage.Total > 0) events.Add(new UsageEvent(ParseTime(Text(message, "timestamp")), Text(message, "model"), usage));
        }
        return BuildFileResult(path, events, sessionId);
    }

    private ToolSummary ScanQwen(string root, DateTimeOffset start)
    {
        var summary = NewSummary("qwen", "Qwen Code", root, true);
        if (!summary.PathExists) return summary;
        foreach (var path in SafeFiles(root, "*.jsonl"))
        {
            var result = Cached(path, ParseQwenFile);
            if (result is null) continue;
            summary.Sessions++;
            foreach (var item in result.Events) Add(summary, item, start);
        }
        if (summary.Sessions == 0) summary.Note = "세션 로그가 없습니다";
        return summary;
    }

    private FileResult? ParseQwenFile(string path)
    {
        var events = new List<UsageEvent>();
        foreach (var line in ReadLines(path))
        {
            if (!line.Contains("usageMetadata", StringComparison.Ordinal) || !TryJson(line, out var doc)) continue;
            using (doc)
            {
                var root = doc.RootElement;
                if (Text(root, "type") != "assistant" || !TryObject(root, "usageMetadata", out var usage)) continue;
                var cached = Long(usage, "cachedContentTokenCount");
                var input = Math.Max(0, Long(usage, "promptTokenCount") - cached);
                var thoughts = Long(usage, "thoughtsTokenCount");
                var output = Long(usage, "candidatesTokenCount") + thoughts;
                var model = Text(root, "model");
                if (model.Length == 0 && TryObject(root, "message", out var message)) model = Text(message, "model");
                if (model.Length == 0) model = "unknown";
                var value = new TokenUsage { Input = input, Output = output, CacheRead = cached, Reasoning = thoughts, Total = input + output + cached };
                if (value.Total > 0) events.Add(new UsageEvent(ParseTime(Text(root, "timestamp")), model, value));
            }
        }
        return BuildFileResult(path, events);
    }

    private ToolSummary ScanCopilot(string root, DateTimeOffset start)
    {
        var summary = NewSummary("copilot", "Copilot CLI", root, true);
        if (!summary.PathExists) return summary;
        var paths = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var directory in SafeDirectories(root))
        {
            var events = Path.Combine(directory, "events.jsonl");
            if (File.Exists(events)) paths[Path.GetFileName(directory)] = events;
        }
        foreach (var path in SafeTopFiles(root, "*.jsonl")) paths.TryAdd(Path.GetFileNameWithoutExtension(path), path);
        foreach (var (sessionId, path) in paths)
        {
            var result = Cached(path, ParseCopilotFile);
            if (result is null) continue;
            summary.Sessions++;
            foreach (var item in result.Events) Add(summary, item, start);
        }
        if (summary.Sessions == 0) summary.Note = "세션 로그가 없습니다";
        return summary;
    }

    private FileResult? ParseCopilotFile(string path)
    {
        var events = new List<UsageEvent>();
        foreach (var line in ReadLines(path))
        {
            if (!line.Contains("session.shutdown", StringComparison.Ordinal) || !TryJson(line, out var doc)) continue;
            using (doc)
            {
                var root = doc.RootElement;
                if (Text(root, "type") != "session.shutdown" || !TryObject(root, "data", out var data) || !TryObject(data, "modelMetrics", out var metrics)) continue;
                foreach (var model in metrics.EnumerateObject())
                {
                    if (!TryObject(model.Value, "usage", out var usage)) continue;
                    var cacheRead = Long(usage, "cacheReadTokens");
                    var cacheWrite = Long(usage, "cacheWriteTokens");
                    var input = Math.Max(0, Long(usage, "inputTokens") - cacheRead - cacheWrite);
                    var output = Long(usage, "outputTokens");
                    var reasoning = Long(usage, "reasoningTokens");
                    var value = new TokenUsage { Input = input, Output = output, CacheRead = cacheRead, CacheWrite = cacheWrite, Reasoning = reasoning, Total = input + output + cacheRead + cacheWrite };
                    var name = model.Name.StartsWith("claude-", StringComparison.Ordinal) ? model.Name.Replace('.', '-') : model.Name;
                    if (value.Total > 0) events.Add(new UsageEvent(ParseTime(Text(root, "timestamp")), name, value));
                }
            }
        }
        return BuildFileResult(path, events);
    }

    private ToolSummary ScanOpenCode(string path, DateTimeOffset start)
    {
        var summary = NewSummary("openCode", "OpenCode", path, File.Exists(path));
        var dbPath = path.EndsWith(".db", StringComparison.OrdinalIgnoreCase) ? path : Path.Combine(path, "opencode.db");
        if (File.Exists(dbPath))
        {
            try
            {
                using var connection = OpenReadOnly(dbPath);
                using var command = connection.CreateCommand();
                command.CommandText = "SELECT time_created, data FROM message WHERE json_extract(data, '$.role') = 'assistant'";
                using var reader = command.ExecuteReader();
                var sessions = new HashSet<string>();
                while (reader.Read())
                {
                    var created = reader.IsDBNull(0) ? 0 : reader.GetInt64(0);
                    var json = reader.GetString(1);
                    if (!TryJson(json, out var doc)) continue;
                    using (doc)
                    {
                        var root = doc.RootElement;
                        var session = Text(root, "sessionID");
                        if (session.Length > 0) sessions.Add(session);
                        var item = OpenCodeEvent(root, created > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(created) : DateTimeOffset.MinValue);
                        if (item is not null) Add(summary, item, start);
                    }
                }
                summary.Sessions = sessions.Count;
            }
            catch { summary.Note = "opencode.db 조회 실패"; }
        }
        else if (Directory.Exists(path))
        {
            var messageDir = Directory.Exists(Path.Combine(path, "storage", "message")) ? Path.Combine(path, "storage", "message") : path;
            var sessions = new HashSet<string>();
            foreach (var file in SafeFiles(messageDir, "*.json"))
            {
                var text = SafeReadAll(file);
                if (text is null || !TryJson(text, out var doc)) continue;
                using (doc)
                {
                    var root = doc.RootElement;
                    if (Text(root, "role") != "assistant") continue;
                    sessions.Add(Directory.GetParent(file)?.Name ?? file);
                    var timestamp = TryObject(root, "time", out var time) ? DateTimeOffset.FromUnixTimeMilliseconds(Long(time, "created")) : new DateTimeOffset(File.GetLastWriteTimeUtc(file));
                    var item = OpenCodeEvent(root, timestamp);
                    if (item is not null) Add(summary, item, start);
                }
            }
            summary.Sessions = sessions.Count;
        }
        else summary.PathExists = false;
        if (summary.Usage.Total == 0 && summary.Note.Length == 0) summary.Note = "사용 기록이 없습니다";
        return summary;
    }

    private static UsageEvent? OpenCodeEvent(JsonElement root, DateTimeOffset timestamp)
    {
        if (!TryObject(root, "tokens", out var tokens)) return null;
        var cacheRead = 0L; var cacheWrite = 0L;
        if (TryObject(tokens, "cache", out var cache)) { cacheRead = Long(cache, "read"); cacheWrite = Long(cache, "write"); }
        var input = Long(tokens, "input"); var output = Long(tokens, "output"); var reasoning = Long(tokens, "reasoning");
        var usage = new TokenUsage { Input = input, Output = output, CacheRead = cacheRead, CacheWrite = cacheWrite, Reasoning = reasoning, Total = input + output + cacheRead + cacheWrite };
        return new UsageEvent(timestamp, Text(root, "modelID"), usage, Double(root, "cost"));
    }

    private ToolSummary ScanCursor(string dbPath, DateTimeOffset start)
    {
        var summary = NewSummary("cursor", "Cursor", dbPath, File.Exists(dbPath));
        if (!summary.PathExists) { summary.Note = "state.vscdb를 찾을 수 없습니다"; return summary; }
        try
        {
            using var connection = OpenReadOnly(dbPath);
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT key, json_extract(value, '$.tokenCount.inputTokens'), json_extract(value, '$.tokenCount.outputTokens') FROM cursorDiskKV WHERE key LIKE 'bubbleId:%' AND (json_extract(value, '$.tokenCount.inputTokens') > 0 OR json_extract(value, '$.tokenCount.outputTokens') > 0)";
            var bubbles = new List<(string Composer, long Input, long Output)>();
            var composers = new HashSet<string>();
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var parts = reader.GetString(0).Split(':', 3);
                    if (parts.Length < 2) continue;
                    var input = reader.IsDBNull(1) ? 0 : reader.GetInt64(1);
                    var output = reader.IsDBNull(2) ? 0 : reader.GetInt64(2);
                    bubbles.Add((parts[1], input, output)); composers.Add(parts[1]);
                }
            }
            var days = new Dictionary<string, DateTimeOffset>();
            foreach (var composer in composers)
            {
                using var dateCommand = connection.CreateCommand();
                dateCommand.CommandText = "SELECT json_extract(value, '$.createdAt') FROM cursorDiskKV WHERE key=$key";
                dateCommand.Parameters.AddWithValue("$key", "composerData:" + composer);
                if (dateCommand.ExecuteScalar() is long milliseconds && milliseconds > 0) days[composer] = DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
            }
            foreach (var bubble in bubbles)
            {
                var usage = new TokenUsage { Input = bubble.Input, Output = bubble.Output, Total = bubble.Input + bubble.Output };
                summary.Usage.Add(usage);
                if (days.TryGetValue(bubble.Composer, out var timestamp)) AddDaily(summary, new UsageEvent(timestamp, "", usage), start);
            }
            summary.Sessions = composers.Count;
            if (bubbles.Count == 0) summary.Note = "토큰 기록이 있는 대화가 없습니다";
        }
        catch { summary.Note = "state.vscdb 조회 실패"; }
        return summary;
    }

    private static SqliteConnection OpenReadOnly(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly }.ToString());
        connection.Open();
        return connection;
    }

    private FileResult? Cached(string path, Func<string, FileResult?> parser)
    {
        try
        {
            var info = new FileInfo(path);
            lock (_cacheLock)
                if (_cache.TryGetValue(path, out var cached) && cached.Length == info.Length && cached.LastWriteUtc == info.LastWriteTimeUtc) return cached;
            var parsed = parser(path);
            if (parsed is not null) lock (_cacheLock) _cache[path] = parsed;
            return parsed;
        }
        catch { return null; }
    }

    private static FileResult BuildFileResult(string path, IEnumerable<UsageEvent> events, string? sessionId = null)
    {
        var info = new FileInfo(path);
        return new FileResult(info.Length, info.LastWriteTimeUtc, sessionId ?? Path.GetFileNameWithoutExtension(path), new TokenUsage(), "", events.ToList());
    }

    private static FileResult EmptyFile(string path) => BuildFileResult(path, []);

    private static ToolSummary NewSummary(string tool, string name, string path, bool filePath = false) => new()
    {
        Tool = tool, DisplayName = name,
        PathExists = filePath ? File.Exists(path) : Directory.Exists(path),
        Note = (filePath ? File.Exists(path) : Directory.Exists(path)) ? "" : "경로를 찾을 수 없습니다"
    };

    private static void Add(ToolSummary summary, UsageEvent item, DateTimeOffset start)
    {
        if (item.Timestamp == DateTimeOffset.MinValue) { summary.Usage.Add(item.Usage); return; }
        summary.Add(item.Timestamp, item.Model == "<synthetic>" ? "" : item.Model, item.Usage, start, item.Cost);
    }

    private static void AddDaily(ToolSummary summary, UsageEvent item, DateTimeOffset start)
    {
        if (item.Timestamp < start || item.Timestamp == DateTimeOffset.MinValue) return;
        var day = item.Timestamp.LocalDateTime.ToString("yyyy-MM-dd");
        if (!summary.Daily.TryGetValue(day, out var daily)) summary.Daily[day] = daily = new TokenUsage();
        daily.Add(item.Usage);
        if (!summary.DailyByModel.TryGetValue(day, out var models)) summary.DailyByModel[day] = models = [];
        if (!models.TryGetValue(item.Model, out var usage)) models[item.Model] = usage = new TokenUsage();
        usage.Add(item.Usage);
    }

    private static TokenUsage CodexUsage(JsonElement value)
    {
        var rawInput = Long(value, "input_tokens"); var cached = Long(value, "cached_input_tokens"); var output = Long(value, "output_tokens");
        var total = Long(value, "total_tokens"); if (total == 0) total = rawInput + output;
        return new TokenUsage { Input = Math.Max(0, rawInput - cached), Output = output, CacheRead = cached, Reasoning = Long(value, "reasoning_output_tokens"), Total = total };
    }

    private static TokenUsage Scale(TokenUsage usage, double factor) => new()
    {
        Input = (long)Math.Round(usage.Input * factor), Output = (long)Math.Round(usage.Output * factor),
        CacheRead = (long)Math.Round(usage.CacheRead * factor), CacheWrite = (long)Math.Round(usage.CacheWrite * factor),
        Reasoning = (long)Math.Round(usage.Reasoning * factor), Total = (long)Math.Round(usage.Total * factor)
    };

    private static IEnumerable<string> SafeFiles(string root, string pattern)
    {
        try { return Directory.Exists(root) ? Directory.EnumerateFiles(root, pattern, SearchOption.AllDirectories).ToArray() : []; }
        catch { return []; }
    }
    private static IEnumerable<string> SafeTopFiles(string root, string pattern) { try { return Directory.EnumerateFiles(root, pattern).ToArray(); } catch { return []; } }
    private static IEnumerable<string> SafeDirectories(string root) { try { return Directory.EnumerateDirectories(root).ToArray(); } catch { return []; } }
    private static IEnumerable<string> ReadLines(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            while (reader.ReadLine() is { } line) yield return line;
        }
        finally { }
    }
    private static string? SafeReadAll(string path) { try { using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); using var reader = new StreamReader(stream); return reader.ReadToEnd(); } catch { return null; } }
    private static bool TryJson(string value, out JsonDocument document) { try { document = JsonDocument.Parse(value, JsonOptions); return true; } catch { document = null!; return false; } }
	private static bool TryObject(JsonElement parent, string name, out JsonElement value)
	{
		value = default;
		return parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.Object;
	}
    private static string Text(JsonElement parent, string name) => parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";
    private static long Long(JsonElement parent, string name) => parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) ? value.ValueKind switch { JsonValueKind.Number => value.TryGetInt64(out var n) ? n : (long)value.GetDouble(), JsonValueKind.String => long.TryParse(value.GetString(), out var n) ? n : 0, _ => 0 } : 0;
    private static double Double(JsonElement parent, string name) => parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) ? value.ValueKind switch { JsonValueKind.Number => value.GetDouble(), JsonValueKind.String => double.TryParse(value.GetString(), out var n) ? n : 0, _ => 0 } : 0;
    private static DateTimeOffset ParseTime(string value) => DateTimeOffset.TryParse(value, out var time) ? time : DateTimeOffset.MinValue;
    private static void SetLatest(ToolSummary summary, DateTime utc) { var value = new DateTimeOffset(utc, TimeSpan.Zero); if (summary.LastActivity is null || value > summary.LastActivity) summary.LastActivity = value; }
}
