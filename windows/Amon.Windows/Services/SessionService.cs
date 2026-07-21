using System.Text;
using System.Text.Json;

namespace AMon;

public sealed class SessionService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly string _historyPath;

    public SessionService(string appDataDirectory) => _historyPath = Path.Combine(appDataDirectory, "history", "sessions.jsonl");

    public Task<IReadOnlyList<SessionRecord>> ScanAsync(ToolPaths paths, CancellationToken cancellationToken = default) => Task.Run<IReadOnlyList<SessionRecord>>(() =>
    {
        var all = Load().ToDictionary(record => record.Id, StringComparer.Ordinal);
        foreach (var record in ScanClaude(paths.Claude).Concat(ScanCodex(paths.Codex))) all[record.Id] = record;
        var merged = all.Values.OrderByDescending(record => record.EndedAt).Take(500).ToArray();
        Save(merged);
        return merged;
    }, cancellationToken);

    public IReadOnlyList<SessionRecord> Load()
    {
        if (!File.Exists(_historyPath)) return [];
        var records = new Dictionary<string, SessionRecord>(StringComparer.Ordinal);
        foreach (var line in File.ReadLines(_historyPath))
        {
            try
            {
                var record = JsonSerializer.Deserialize<SessionRecord>(line, JsonOptions);
                if (record is not null && record.SessionId.Length > 0) records[record.Id] = record;
            }
            catch { }
        }
        return records.Values.OrderByDescending(record => record.EndedAt).ToArray();
    }

    private void Save(IReadOnlyList<SessionRecord> records)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_historyPath)!);
        var temporary = _historyPath + ".tmp";
        using (var writer = new StreamWriter(temporary, false, new UTF8Encoding(false)))
            foreach (var record in records.Reverse()) writer.WriteLine(JsonSerializer.Serialize(record, JsonOptions));
        File.Move(temporary, _historyPath, true);
    }

    private static IEnumerable<SessionRecord> ScanCodex(string root)
    {
        foreach (var path in RecentFiles(root, "rollout-*.jsonl"))
        {
            SessionRecord? record = null;
            try
            {
                var sessionId = ""; var cwd = ""; var model = "unknown"; var lastResult = "";
                DateTimeOffset? first = null, last = null;
                long input = 0, cached = 0, output = 0, total = 0;
                var prompts = new List<string>(); var seen = new HashSet<string>();
                foreach (var line in SharedReadLines(path))
                {
                    if (!TryJson(line, out var doc)) continue;
                    using (doc)
                    {
                        var rootElement = doc.RootElement;
                        if (DateTimeOffset.TryParse(Text(rootElement, "timestamp"), out var timestamp)) { first ??= timestamp; last = timestamp; }
                        if (!TryObject(rootElement, "payload", out var payload)) continue;
                        switch (Text(rootElement, "type"))
                        {
                            case "session_meta":
                                sessionId = Text(payload, "id") is { Length: > 0 } id ? id : sessionId;
								if (Text(payload, "cwd") is { Length: > 0 } sessionCwd) cwd = sessionCwd;
                                break;
                            case "turn_context":
								if (Text(payload, "cwd") is { Length: > 0 } turnCwd) cwd = turnCwd;
                                model = Text(payload, "model") is { Length: > 0 } next ? next : model;
                                break;
                            case "event_msg":
                                if (Text(payload, "type") == "user_message") AddPrompt(prompts, seen, Text(payload, "message"));
                                if (Text(payload, "type") == "token_count" && TryObject(payload, "info", out var info) && TryObject(info, "total_token_usage", out var usage))
                                {
                                    input = Long(usage, "input_tokens"); cached = Long(usage, "cached_input_tokens"); output = Long(usage, "output_tokens"); total = Long(usage, "total_tokens");
                                    if (total == 0) total = input + output;
                                }
                                break;
                            case "response_item":
                                var role = Text(payload, "role");
                                if (role == "user") AddPrompt(prompts, seen, ContentText(payload, "input_text"));
                                else if (role == "assistant") lastResult = FirstLine(ContentText(payload, "output_text"), 200);
                                break;
                        }
                    }
                }
                if (sessionId.Length > 0 && first is not null && last is not null && total > 0)
                    record = new SessionRecord
                    {
                        Provider = "codex", SessionId = sessionId, ProjectLabel = Path.GetFileName(cwd), StartedAt = first.Value, EndedAt = last.Value,
                        Prompts = prompts.TakeLast(50).ToList(), PromptCount = prompts.Count, CurrentTask = prompts.LastOrDefault() ?? "", LastResult = lastResult,
                        InputTokens = Math.Max(0, input - cached), OutputTokens = output, CacheTokens = cached, TotalTokens = total,
                        Models = new Dictionary<string, long> { [model] = total }, SourcePath = path
                    };
            }
            catch { }
            if (record is not null) yield return record;
        }
    }

    private static IEnumerable<SessionRecord> ScanClaude(string root)
    {
        foreach (var path in RecentFiles(root, "*.jsonl").Where(path => !path.Contains($"{Path.DirectorySeparatorChar}subagents{Path.DirectorySeparatorChar}")))
        {
            SessionRecord? record = null;
            try
            {
                var messages = new Dictionary<string, (long Input, long Output, long Read, long Write, string Model)>();
                var prompts = new List<string>(); var seenPrompts = new HashSet<string>(); var lastResult = ""; var cwd = ""; var branch = "";
                DateTimeOffset? first = null, last = null;
                foreach (var line in SharedReadLines(path))
                {
                    if (!TryJson(line, out var doc)) continue;
                    using (doc)
                    {
                        var rootElement = doc.RootElement;
                        if (DateTimeOffset.TryParse(Text(rootElement, "timestamp"), out var timestamp)) { first ??= timestamp; last = timestamp; }
						if (Text(rootElement, "cwd") is { Length: > 0 } nextCwd) cwd = nextCwd;
						if (Text(rootElement, "gitBranch") is { Length: > 0 } nextBranch) branch = nextBranch;
                        if (!TryObject(rootElement, "message", out var message)) continue;
                        var type = Text(rootElement, "type");
                        if (type == "user") AddPrompt(prompts, seenPrompts, ContentText(message, "text"));
                        if (type != "assistant") continue;
                        var assistantText = ContentText(message, "text"); if (assistantText.Length > 0) lastResult = FirstLine(assistantText, 200);
                        if (!TryObject(message, "usage", out var usage)) continue;
                        var key = Text(message, "id") + "|" + Text(rootElement, "requestId");
                        messages[key] = (Long(usage, "input_tokens"), Long(usage, "output_tokens"), Long(usage, "cache_read_input_tokens"), Long(usage, "cache_creation_input_tokens"), Text(message, "model"));
                    }
                }
                var input = messages.Values.Sum(item => item.Input); var output = messages.Values.Sum(item => item.Output);
                var cache = messages.Values.Sum(item => item.Read + item.Write); var total = input + output + cache;
                if (first is not null && last is not null && total > 0)
                {
                    var models = messages.Values.Where(item => item.Model.Length > 0 && item.Model != "<synthetic>").GroupBy(item => item.Model).ToDictionary(group => group.Key, group => group.Sum(item => item.Input + item.Output + item.Read + item.Write));
                    record = new SessionRecord
                    {
                        Provider = "claude", SessionId = Path.GetFileNameWithoutExtension(path), ProjectLabel = Path.GetFileName(cwd), GitBranch = branch,
                        StartedAt = first.Value, EndedAt = last.Value, Prompts = prompts.TakeLast(50).ToList(), PromptCount = prompts.Count,
                        CurrentTask = prompts.LastOrDefault() ?? "", LastResult = lastResult, InputTokens = input, OutputTokens = output,
                        CacheTokens = cache, TotalTokens = total, Models = models, SourcePath = path
                    };
                }
            }
            catch { }
            if (record is not null) yield return record;
        }
    }

    private static IEnumerable<string> RecentFiles(string root, string pattern)
    {
        try { return Directory.Exists(root) ? Directory.EnumerateFiles(root, pattern, SearchOption.AllDirectories).OrderByDescending(File.GetLastWriteTimeUtc).Take(200).ToArray() : []; }
        catch { return []; }
    }
    private static void AddPrompt(List<string> prompts, HashSet<string> seen, string value)
    {
        var line = FirstLine(value, 120);
        if (line.Length == 0 || line.StartsWith("<environment_context>") || line.StartsWith("<permissions instructions>") || line.StartsWith("# AGENTS.md instructions") || !seen.Add(line)) return;
        prompts.Add(line);
    }
    private static string ContentText(JsonElement parent, string blockType)
    {
        if (!parent.TryGetProperty("content", out var content)) return Text(parent, "text");
        if (content.ValueKind == JsonValueKind.String) return content.GetString() ?? "";
        if (content.ValueKind != JsonValueKind.Array) return "";
        return string.Join(" ", content.EnumerateArray().Where(item => Text(item, "type") == blockType || (blockType == "text" && Text(item, "type") == "text")).Select(item => Text(item, "text")));
    }
    private static string FirstLine(string value, int limit) { var line = value.Trim().Split(['\r', '\n'], 2)[0].Trim(); return line.Length <= limit ? line : line[..limit]; }
    private static IEnumerable<string> SharedReadLines(string path) { using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); using var reader = new StreamReader(stream); while (reader.ReadLine() is { } line) yield return line; }
    private static bool TryJson(string value, out JsonDocument document) { try { document = JsonDocument.Parse(value); return true; } catch { document = null!; return false; } }
	private static bool TryObject(JsonElement parent, string name, out JsonElement value)
	{
		value = default;
		return parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.Object;
	}
    private static string Text(JsonElement parent, string name) => parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";
    private static long Long(JsonElement parent, string name) => parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) ? number : 0;
}
