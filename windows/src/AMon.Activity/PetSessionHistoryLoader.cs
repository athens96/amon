using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AMon.Activity;

/// One past turn on the pet's history stack: the user's prompt and that turn's last reply summary.
public sealed record PetHistoryTurn(
    int Id,
    string Prompt,
    string? Reply,
    DateTimeOffset? Timestamp,
    long? InputTokens,
    long? OutputTokens);

/// Builds the recent-turn list when the history button is pressed — read once on demand, not
/// polled. Sources are the same files the live view uses: Claude's hook-recorded transcript JSONL
/// and Codex's rollout log. Cursor has no stable local turn log and gets no history.
/// Ported from the macOS `PetSessionHistoryLoader`.
public static class PetSessionHistoryLoader
{
    /// Tail windows widened step by step — a session with large tool output can have its last
    /// human prompt more than 4 MB from the end. Stop at the first window that yields turns, or
    /// once the whole file has been read.
    public static readonly int[] TailWindows = [4_194_304, 16_777_216, 67_108_864];
    public const int MaxTurns = 50;
    public const int PromptLimit = 160;
    public const int ReplyLimit = 200;

    public static IReadOnlyList<PetHistoryTurn> Load(string? provider, string? transcriptPath)
    {
        if (string.IsNullOrWhiteSpace(transcriptPath) || !File.Exists(transcriptPath))
            return [];
        foreach (var window in TailWindows)
        {
            var (lines, readWholeFile) = ReadTail(transcriptPath, window);
            if (lines is null)
                return [];
            var turns = provider switch
            {
                "claude" => ClaudeTurns(lines),
                "codex" => CodexTurns(lines),
                _ => [],
            };
            if (turns.Count > 0)
                return turns;
            if (readWholeFile)
                return [];
        }
        return [];
    }

    /// Claude transcript JSONL — a typed/sdk user prompt opens a turn; the last assistant text
    /// after it is the reply (same rule as the live output; subagent lines excluded).
    public static IReadOnlyList<PetHistoryTurn> ClaudeTurns(IEnumerable<string> lines)
    {
        var turns = new List<PetHistoryTurn>();
        foreach (var line in lines)
        {
            using var document = TryParse(line);
            if (document is null)
                continue;
            var root = document.RootElement;
            if (Bool(root, "isSidechain") == true)
                continue;
            var message = Object(root, "message");
            switch (Text(root, "type"))
            {
                case "user":
                    if (!IsHumanPromptSource(Text(root, "promptSource")))
                        continue;
                    var promptText = message is { } userMessage ? HumanPromptText(userMessage) : null;
                    if (promptText is null || FirstLine(promptText, PromptLimit) is not { } prompt)
                        continue;
                    turns.Add(new PetHistoryTurn(turns.Count, prompt, null, ParseIso(Text(root, "timestamp")), null, null));
                    break;
                case "assistant":
                    if (turns.Count == 0)
                        continue;
                    var last = turns[^1];
                    if (message is { } assistantMessage && Object(assistantMessage, "usage") is { } usage)
                    {
                        var output = Long(usage, "output_tokens") ?? 0;
                        if (output > 0)
                            last = last with { OutputTokens = (last.OutputTokens ?? 0) + output };
                        // With prompt caching input_tokens is a handful; add cache reads/writes for
                        // the real context size of the last call.
                        var input = (Long(usage, "input_tokens") ?? 0)
                            + (Long(usage, "cache_read_input_tokens") ?? 0)
                            + (Long(usage, "cache_creation_input_tokens") ?? 0);
                        if (input > 0)
                            last = last with { InputTokens = input };
                    }
                    if (message is { } replyMessage && AssistantText(replyMessage) is { } text && FirstLine(text, ReplyLimit) is { } reply)
                        last = last with { Reply = reply };
                    turns[^1] = last;
                    break;
            }
        }
        return Tail(turns);
    }

    /// Codex rollout JSONL — `event_msg` user_message opens a turn, agent_message fills the reply,
    /// and the delta of the cumulative `token_count` fills the tokens. Rollouts without any
    /// `event_msg` fall back to `response_item` user/assistant messages (no token data).
    public static IReadOnlyList<PetHistoryTurn> CodexTurns(IEnumerable<string> lines)
    {
        var turns = new List<PetHistoryTurn>();
        var fallback = new List<PetHistoryTurn>();
        long cumulativeInput = 0, cumulativeOutput = 0, baseInput = 0, baseOutput = 0;
        foreach (var line in lines)
        {
            using var document = TryParse(line);
            if (document is null)
                continue;
            var root = document.RootElement;
            if (Object(root, "payload") is not { } payload)
                continue;
            var type = Text(root, "type");
            if (type == "response_item")
            {
                AppendCodexResponseItem(payload, ParseIso(Text(root, "timestamp")), fallback);
                continue;
            }
            if (type != "event_msg")
                continue;
            switch (Text(payload, "type"))
            {
                case "user_message":
                    if (FirstLine(Text(payload, "message"), PromptLimit) is not { } prompt)
                        continue;
                    baseInput = cumulativeInput;
                    baseOutput = cumulativeOutput;
                    turns.Add(new PetHistoryTurn(turns.Count, prompt, null, ParseIso(Text(root, "timestamp")), null, null));
                    break;
                case "agent_message":
                    if (turns.Count == 0 || FirstLine(Text(payload, "message"), ReplyLimit) is not { } reply)
                        continue;
                    turns[^1] = turns[^1] with { Reply = reply };
                    break;
                case "token_count":
                    if (Object(payload, "info") is not { } info || Object(info, "total_token_usage") is not { } total)
                        continue;
                    var cached = Long(total, "cached_input_tokens") ?? 0;
                    if (Long(total, "input_tokens") is { } rawInput)
                        cumulativeInput = Math.Max(rawInput - cached, 0);
                    if (Long(total, "output_tokens") is { } rawOutput)
                        cumulativeOutput = rawOutput;
                    if (turns.Count == 0)
                        continue;
                    var last = turns[^1];
                    var turnInput = cumulativeInput - baseInput;
                    var turnOutput = cumulativeOutput - baseOutput;
                    turns[^1] = last with
                    {
                        InputTokens = turnInput > 0 ? turnInput : last.InputTokens,
                        OutputTokens = turnOutput > 0 ? turnOutput : last.OutputTokens,
                    };
                    break;
            }
        }
        return Tail(turns.Count == 0 ? fallback : turns);
    }

    private static void AppendCodexResponseItem(JsonElement payload, DateTimeOffset? timestamp, List<PetHistoryTurn> turns)
    {
        if (Text(payload, "type") != "message" || Array(payload, "content") is not { } content)
            return;
        switch (Text(payload, "role"))
        {
            case "user":
                foreach (var block in content.EnumerateArray())
                {
                    if (Text(block, "type") != "input_text")
                        continue;
                    var text = Text(block, "text");
                    if (text is null || !LiveText.IsCodexUserText(text) || FirstLine(text, PromptLimit) is not { } prompt)
                        continue;
                    turns.Add(new PetHistoryTurn(turns.Count, prompt, null, timestamp, null, null));
                    return;
                }
                break;
            case "assistant":
                if (turns.Count == 0)
                    return;
                foreach (var block in content.EnumerateArray())
                {
                    if (Text(block, "type") != "output_text" || FirstLine(Text(block, "text"), ReplyLimit) is not { } reply)
                        continue;
                    turns[^1] = turns[^1] with { Reply = reply };
                    return;
                }
                break;
        }
    }

    // MARK: - Shared Claude rules (mirror the hook's extract_prompt_text / extract_assistant_text)

    private static readonly string[] InjectedPrefixes =
        ["<command-", "<local-command", "<system-reminder", "<user-prompt-submit-hook", "<task-notification"];

    public static bool IsHumanPromptSource(string? source) => source is "typed" or "sdk";

    /// Only what the human typed — tool_result round trips and injected text are not prompts.
    public static string? HumanPromptText(JsonElement message)
    {
        if (!message.TryGetProperty("content", out var content))
            return null;
        if (content.ValueKind == JsonValueKind.String)
            return IsRealPrompt(content.GetString()) ? content.GetString() : null;
        if (content.ValueKind != JsonValueKind.Array)
            return null;
        var blocks = content.EnumerateArray().ToArray();
        if (blocks.Any(block => Text(block, "type") == "tool_result"))
            return null;
        foreach (var block in blocks)
        {
            if (Text(block, "type") == "text" && Text(block, "text") is { } text && IsRealPrompt(text))
                return text;
        }
        return null;
    }

    /// Human-readable assistant text only — tool_use and thinking blocks are skipped.
    public static string? AssistantText(JsonElement message)
    {
        if (!message.TryGetProperty("content", out var content))
            return null;
        if (content.ValueKind == JsonValueKind.String)
        {
            var trimmed = content.GetString()?.Trim();
            return string.IsNullOrEmpty(trimmed) ? null : trimmed;
        }
        if (content.ValueKind != JsonValueKind.Array)
            return null;
        var joined = string.Join(" ", content.EnumerateArray()
            .Where(static block => Text(block, "type") == "text")
            .Select(static block => Text(block, "text"))
            .Where(static text => !string.IsNullOrEmpty(text))).Trim();
        return joined.Length == 0 ? null : joined;
    }

    private static bool IsRealPrompt(string? text)
    {
        var trimmed = text?.Trim();
        return !string.IsNullOrEmpty(trimmed) && !InjectedPrefixes.Any(prefix => trimmed.StartsWith(prefix, StringComparison.Ordinal));
    }

    public static string? FirstLine(string? text, int limit)
    {
        if (text is null)
            return null;
        var line = text.Split('\n', 2)[0].Trim();
        if (line.Length == 0)
            return null;
        return line.Length <= limit ? line : line[..limit];
    }

    // MARK: - I/O and JSON helpers

    /// The last `bytes` of the file as lines (the first, possibly cut, line dropped when the window
    /// did not start at the file's beginning), plus whether the whole file was read.
    private static (IReadOnlyList<string>? Lines, bool WholeFile) ReadTail(string path, int bytes)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var wholeFile = stream.Length <= bytes;
            var offset = wholeFile ? 0 : stream.Length - bytes;
            stream.Seek(offset, SeekOrigin.Begin);
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: false);
            var text = reader.ReadToEnd();
            var lines = text.Split('\n');
            IEnumerable<string> usable = lines;
            if (!wholeFile && lines.Length > 0)
                usable = lines.Skip(1);
            return (usable.Where(static line => line.Length > 0).ToArray(), wholeFile);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return (null, false);
        }
    }

    private static IReadOnlyList<PetHistoryTurn> Tail(List<PetHistoryTurn> turns) =>
        turns.Count <= MaxTurns ? turns : turns.Skip(turns.Count - MaxTurns).ToArray();

    private static JsonDocument? TryParse(string line)
    {
        try
        {
            var document = JsonDocument.Parse(line);
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

    private static DateTimeOffset? ParseIso(string? value) =>
        value is not null
        && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
            ? parsed
            : null;

    private static string? Text(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static bool? Bool(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value)
            ? value.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null }
            : null;

    private static long? Long(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number)
            ? number
            : null;

    private static JsonElement? Object(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Object
            ? value
            : null;

    private static JsonElement? Array(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Array
            ? value
            : null;
}
