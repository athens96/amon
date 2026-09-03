using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace AMon.Activity;

/// One ended Cursor conversation (composer) reconstructed from the global `state.vscdb`.
public sealed record CursorSessionSummary(
    string Id,
    string? ProjectLabel,
    DateTimeOffset StartedAt,
    DateTimeOffset EndedAt,
    IReadOnlyList<string> Prompts,
    int PromptCount,
    string? LastResult,
    string? Model,
    int AgentCount);

public sealed record CursorTurn(bool IsUser, string Text, DateTimeOffset? Timestamp);

/// A `toolFormerData` entry on a bubble: the tool name plus its decoded parameters (or `null`).
public sealed record CursorToolCall(string Name, JsonElement? Parameters, DateTimeOffset? Timestamp);

/// Ported from the macOS `CursorStateDB` + `SessionHistoryScanner.cursorSessions`: Cursor keeps
/// conversations in the global `cursorDiskKV` table — one `composerData:<id>` row plus one
/// `bubbleId:<composerId>:<bubbleId>` row per message (type 1 = user, 2 = assistant). Workspace
/// databases only retain the composer id list, which is how a conversation gets its project label.
///
/// Two measured traps: the database is WAL-journaled, so `immutable=1` hides recent turns until a
/// checkpoint — `mode=ro` is tried first; and listing must use a `key` range, not `LIKE`, or a
/// multi-gigabyte database is full-scanned on every refresh.
public static class CursorSessionHistory
{
    /// A composer updated more recently than this may still be in progress and belongs to the
    /// live view, not the history.
    public static readonly TimeSpan ActiveGrace = TimeSpan.FromMinutes(15);
    public const int SessionLimit = 200;
    public const int MaxPrompts = 12;
    private const int BubbleFetchCap = 12;

    public static string DefaultDatabasePath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Cursor", "User", "globalStorage", "state.vscdb");

    /// The configured value when it names an existing `.vscdb` file, otherwise the default global
    /// database; `null` when neither exists.
    public static string? ResolveDatabasePath(string? configured)
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            var expanded = Environment.ExpandEnvironmentVariables(configured.Trim());
            if (expanded.StartsWith("~/", StringComparison.Ordinal) || expanded.StartsWith("~\\", StringComparison.Ordinal))
                expanded = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), expanded[2..]);
            if (string.Equals(Path.GetExtension(expanded), ".vscdb", StringComparison.OrdinalIgnoreCase) && File.Exists(expanded))
                return Path.GetFullPath(expanded);
        }
        var fallback = DefaultDatabasePath();
        return File.Exists(fallback) ? fallback : null;
    }

    /// Ended conversations, most recent first, capped at `SessionLimit`.
    public static IReadOnlyList<CursorSessionSummary> Scan(string databasePath, DateTimeOffset now)
    {
        using var connection = Open(databasePath);
        if (connection is null)
            return [];
        var ended = ListComposers(connection)
            .Where(meta => meta.UpdatedAt is { } updated && now - updated > ActiveGrace)
            .OrderByDescending(static meta => meta.UpdatedAt)
            .Take(SessionLimit)
            .ToArray();
        if (ended.Length == 0)
            return [];

        var labels = WorkspaceLabels(databasePath, ended.Select(static meta => meta.Id).ToHashSet(StringComparer.Ordinal));
        var summaries = new List<CursorSessionSummary>();
        foreach (var meta in ended)
        {
            var summary = Summarize(connection, meta, labels.GetValueOrDefault(meta.Id));
            if (summary is not null)
                summaries.Add(summary);
        }
        return summaries;
    }

    /// The conversation in header order. Bubbles without text (tool steps, context-only bubbles)
    /// are execution detail, not dialogue, and are skipped. Assistant narration and the final answer
    /// are separate bubbles and stay separate turns.
    public static IReadOnlyList<CursorTurn> ReadTurns(string databasePath, string composerId)
    {
        using var connection = Open(databasePath);
        if (connection is null || ReadComposer(connection, composerId) is not { } composer)
            return [];
        var turns = new List<CursorTurn>();
        foreach (var header in composer.Headers.Where(static header => header.Type is 1 or 2))
        {
            var bubble = ReadBubble(connection, composer.Id, header.BubbleId);
            if (bubble is null || string.IsNullOrWhiteSpace(bubble.Text))
                continue;
            turns.Add(new CursorTurn(header.Type == 1, bubble.Text, bubble.CreatedAt ?? header.CreatedAt));
        }
        return turns;
    }

    /// Every `toolFormerData` on the conversation's bubbles, in header order.
    public static IReadOnlyList<CursorToolCall> ReadToolCalls(string databasePath, string composerId)
    {
        using var connection = Open(databasePath);
        if (connection is null || ReadComposer(connection, composerId) is not { } composer)
            return [];
        var calls = new List<CursorToolCall>();
        foreach (var header in composer.Headers)
        {
            var json = Value(connection, $"bubbleId:{composer.Id}:{header.BubbleId}");
            if (json is null)
                continue;
            try
            {
                using var document = JsonDocument.Parse(json);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object
                    || !root.TryGetProperty("toolFormerData", out var tool)
                    || tool.ValueKind != JsonValueKind.Object)
                    continue;
                var name = Text(tool, "name");
                if (string.IsNullOrWhiteSpace(name))
                    continue;
                calls.Add(new CursorToolCall(
                    name,
                    DecodeObject(tool, "params") ?? DecodeObject(tool, "rawArgs"),
                    ParseDate(root.TryGetProperty("createdAt", out var created) ? created : default) ?? header.CreatedAt));
            }
            catch (JsonException)
            {
                // One malformed bubble must not hide the rest of the audit.
            }
        }
        return calls;
    }

    // MARK: - Composer + bubble access

    internal sealed record ComposerMeta(string Id, DateTimeOffset? CreatedAt, DateTimeOffset? UpdatedAt);

    internal sealed record BubbleHeader(string BubbleId, int Type, DateTimeOffset? CreatedAt);

    internal sealed record Composer(
        string Id,
        string? Name,
        DateTimeOffset? CreatedAt,
        DateTimeOffset? UpdatedAt,
        string? ModelName,
        int SubagentCount,
        IReadOnlyList<BubbleHeader> Headers);

    internal sealed record Bubble(string Text, DateTimeOffset? CreatedAt);

    /// `mode=ro` first (sees WAL contents), `immutable=1` only as a fallback; `null` when neither opens.
    internal static SqliteConnection? Open(string databasePath)
    {
        if (!File.Exists(databasePath))
            return null;
        foreach (var immutable in new[] { false, true })
        {
            var dataSource = immutable ? new Uri(databasePath).AbsoluteUri + "?immutable=1" : databasePath;
            var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = dataSource,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false,
                DefaultTimeout = 1,
            }.ToString());
            try
            {
                connection.Open();
                using var probe = connection.CreateCommand();
                probe.CommandText = "SELECT 1 FROM sqlite_master LIMIT 1";
                probe.ExecuteScalar();
                return connection;
            }
            catch (SqliteException)
            {
                connection.Dispose();
            }
        }
        return null;
    }

    internal static IReadOnlyList<ComposerMeta> ListComposers(SqliteConnection connection)
    {
        var metas = new List<ComposerMeta>();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT substr(key, 14),
                   CAST(json_extract(CAST(value AS TEXT), '$.createdAt') AS INTEGER),
                   CAST(json_extract(CAST(value AS TEXT), '$.lastUpdatedAt') AS INTEGER)
              FROM cursorDiskKV
             WHERE key > 'composerData:' AND key < 'composerData;'
            """;
        try
        {
            using var rows = command.ExecuteReader();
            while (rows.Read())
            {
                metas.Add(new ComposerMeta(
                    rows.GetString(0),
                    FromEpoch(rows.IsDBNull(1) ? 0 : rows.GetInt64(1)),
                    FromEpoch(rows.IsDBNull(2) ? 0 : rows.GetInt64(2))));
            }
        }
        catch (SqliteException)
        {
            return [];
        }
        return metas;
    }

    internal static Composer? ReadComposer(SqliteConnection connection, string id)
    {
        var json = Value(connection, "composerData:" + id);
        if (json is null)
            return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return null;
            var headers = new List<BubbleHeader>();
            if (root.TryGetProperty("fullConversationHeadersOnly", out var headerArray) && headerArray.ValueKind == JsonValueKind.Array)
            {
                foreach (var header in headerArray.EnumerateArray())
                {
                    if (header.ValueKind != JsonValueKind.Object || Text(header, "bubbleId") is not { Length: > 0 } bubbleId)
                        continue;
                    var type = header.TryGetProperty("type", out var typeValue) && typeValue.ValueKind == JsonValueKind.Number && typeValue.TryGetInt32(out var parsed)
                        ? parsed
                        : 0;
                    headers.Add(new BubbleHeader(bubbleId, type, ParseDate(header.TryGetProperty("createdAt", out var created) ? created : default)));
                }
            }
            var model = root.TryGetProperty("modelConfig", out var config) ? Text(config, "modelName")?.Trim() : null;
            if (string.IsNullOrEmpty(model) || string.Equals(model, "default", StringComparison.OrdinalIgnoreCase))
                model = null;
            var name = Text(root, "name")?.Trim();
            var subagents = root.TryGetProperty("subagentComposerIds", out var subagentIds) && subagentIds.ValueKind == JsonValueKind.Array
                ? subagentIds.GetArrayLength()
                : 0;
            return new Composer(
                Text(root, "composerId") ?? id,
                string.IsNullOrEmpty(name) ? null : name,
                ParseDate(root.TryGetProperty("createdAt", out var createdAt) ? createdAt : default),
                ParseDate(root.TryGetProperty("lastUpdatedAt", out var updatedAt) ? updatedAt : default),
                model,
                subagents,
                headers);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    internal static Bubble? ReadBubble(SqliteConnection connection, string composerId, string bubbleId)
    {
        var json = Value(connection, $"bubbleId:{composerId}:{bubbleId}");
        if (json is null)
            return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return null;
            return new Bubble(
                Text(root, "text")?.Trim() ?? string.Empty,
                ParseDate(root.TryGetProperty("createdAt", out var created) ? created : default));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static CursorSessionSummary? Summarize(SqliteConnection connection, ComposerMeta meta, string? label)
    {
        if (ReadComposer(connection, meta.Id) is not { } composer)
            return null;

        // The first line of every user bubble is the request list; empty bodies (context-only
        // bubbles) are not requests. Only the newest `MaxPrompts` are kept, so bubbles are read from
        // the end and reading stops once enough were found — a long composer costs 12 lookups, not
        // one per turn. A composer with no request (an empty draft) is not recorded.
        var userHeaders = composer.Headers.Where(static header => header.Type == 1).ToArray();
        var prompts = new List<string>();
        var visited = 0;
        foreach (var header in userHeaders.Reverse())
        {
            if (prompts.Count >= MaxPrompts)
                break;
            visited++;
            var bubble = ReadBubble(connection, meta.Id, header.BubbleId);
            if (bubble is null || LiveText.FirstLine(bubble.Text, 120) is not { } line)
                continue;
            prompts.Insert(0, line);
        }
        if (prompts.Count == 0)
            return null;
        // Exact when every user bubble was inspected; beyond the cap the uninspected headers are
        // assumed to be requests (empty context-only bubbles are the exception, not the rule).
        var promptCount = prompts.Count + (userHeaders.Length - visited);

        var started = composer.CreatedAt
            ?? composer.Headers.FirstOrDefault()?.CreatedAt
            ?? meta.UpdatedAt
            ?? DateTimeOffset.UtcNow;
        var ended = composer.UpdatedAt ?? meta.UpdatedAt ?? started;
        return new CursorSessionSummary(
            meta.Id,
            label,
            started,
            ended,
            prompts,
            promptCount,
            LatestText(connection, composer with { Id = meta.Id }, type: 2, limit: 200),
            composer.ModelName,
            composer.SubagentCount);
    }

    /// The newest non-empty bubble of `type`, scanning from the end with a point-lookup cap since
    /// empty tool-step bubbles are common.
    private static string? LatestText(SqliteConnection connection, Composer composer, int type, int limit)
    {
        var fetched = 0;
        foreach (var header in composer.Headers.Reverse().Where(header => header.Type == type))
        {
            if (fetched++ >= BubbleFetchCap)
                break;
            var bubble = ReadBubble(connection, composer.Id, header.BubbleId);
            if (bubble is null || string.IsNullOrWhiteSpace(bubble.Text))
                continue;
            return LiveText.FirstLine(bubble.Text, limit);
        }
        return null;
    }

    // MARK: - Workspace labels

    /// composer id → workspace folder name. The global database carries no project information, so
    /// membership is looked up in each workspace's `state.vscdb` (`composer.composerData`), most
    /// recently modified first, and the label comes from that workspace's `workspace.json`.
    internal static IReadOnlyDictionary<string, string> WorkspaceLabels(string globalDatabasePath, ISet<string> ids)
    {
        var labels = new Dictionary<string, string>(StringComparer.Ordinal);
        if (ids.Count == 0)
            return labels;
        var userRoot = Path.GetDirectoryName(Path.GetDirectoryName(globalDatabasePath));
        if (userRoot is null)
            return labels;
        var workspaceRoot = Path.Combine(userRoot, "workspaceStorage");
        if (!Directory.Exists(workspaceRoot))
            return labels;

        IEnumerable<string> candidates;
        try
        {
            candidates = Directory.EnumerateDirectories(workspaceRoot)
                .Select(directory => Path.Combine(directory, "state.vscdb"))
                .Where(File.Exists)
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .Take(30)
                .ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return labels;
        }

        var remaining = new HashSet<string>(ids, StringComparer.Ordinal);
        foreach (var candidate in candidates)
        {
            if (remaining.Count == 0)
                break;
            var members = WorkspaceComposerIds(candidate);
            var hits = remaining.Where(members.Contains).ToArray();
            if (hits.Length == 0)
                continue;
            remaining.ExceptWith(hits);
            var label = WorkspaceLabel(candidate);
            if (label is null)
                continue;
            foreach (var hit in hits)
                labels[hit] = label;
        }
        return labels;
    }

    private static HashSet<string> WorkspaceComposerIds(string databasePath)
    {
        var members = new HashSet<string>(StringComparer.Ordinal);
        using var connection = Open(databasePath);
        if (connection is null)
            return members;
        string? json;
        try
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT value FROM ItemTable WHERE key = 'composer.composerData'";
            json = command.ExecuteScalar() as string;
        }
        catch (SqliteException)
        {
            return members;
        }
        if (json is null)
            return members;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return members;
            foreach (var key in new[] { "selectedComposerIds", "lastFocusedComposerIds" })
            {
                if (root.TryGetProperty(key, out var list) && list.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in list.EnumerateArray())
                    {
                        if (item.ValueKind == JsonValueKind.String && item.GetString() is { Length: > 0 } id)
                            members.Add(id);
                    }
                }
            }
            if (root.TryGetProperty("allComposers", out var all) && all.ValueKind == JsonValueKind.Array)
            {
                foreach (var composer in all.EnumerateArray())
                {
                    if (Text(composer, "composerId") is { Length: > 0 } id)
                        members.Add(id);
                }
            }
        }
        catch (JsonException)
        {
        }
        return members;
    }

    private static string? WorkspaceLabel(string databasePath)
    {
        var workspaceFile = Path.Combine(Path.GetDirectoryName(databasePath) ?? string.Empty, "workspace.json");
        if (!File.Exists(workspaceFile))
            return null;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(workspaceFile));
            var folder = Text(document.RootElement, "folder") ?? Text(document.RootElement, "workspace");
            if (string.IsNullOrWhiteSpace(folder))
                return null;
            var path = folder.StartsWith("file://", StringComparison.OrdinalIgnoreCase)
                ? Uri.UnescapeDataString(folder["file://".Length..].TrimStart('/'))
                : folder;
            var label = Path.GetFileName(path.TrimEnd('/', '\\'));
            return string.IsNullOrEmpty(label) ? null : label;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    // MARK: - Helpers

    private static string? Value(SqliteConnection connection, string key)
    {
        try
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT value FROM cursorDiskKV WHERE key=$key";
            command.Parameters.AddWithValue("$key", key);
            return command.ExecuteScalar() switch
            {
                string text => text,
                byte[] bytes => System.Text.Encoding.UTF8.GetString(bytes),
                _ => null,
            };
        }
        catch (SqliteException)
        {
            return null;
        }
    }

    private static JsonElement? DecodeObject(JsonElement tool, string name)
    {
        if (!tool.TryGetProperty(name, out var value))
            return null;
        if (value.ValueKind == JsonValueKind.Object)
            return value.Clone();
        if (value.ValueKind != JsonValueKind.String)
            return null;
        try
        {
            using var document = JsonDocument.Parse(value.GetString() ?? string.Empty);
            return document.RootElement.ValueKind == JsonValueKind.Object ? document.RootElement.Clone() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// `composerData` timestamps are epoch milliseconds; bubble `createdAt` is an ISO string.
    private static DateTimeOffset? ParseDate(JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Number when value.TryGetInt64(out var epoch):
                return FromEpoch(epoch);
            case JsonValueKind.String:
                var text = value.GetString();
                if (long.TryParse(text, out var parsedEpoch))
                    return FromEpoch(parsedEpoch);
                return DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var date)
                    ? date
                    : null;
            default:
                return null;
        }
    }

    private static DateTimeOffset? FromEpoch(long epoch)
    {
        if (epoch <= 0)
            return null;
        try
        {
            return epoch > 10_000_000_000
                ? DateTimeOffset.FromUnixTimeMilliseconds(epoch)
                : DateTimeOffset.FromUnixTimeSeconds(epoch);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement element, string property) =>
        element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty(property, out var value)
        && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}
