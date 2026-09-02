using System.Text.Json;
using System.Text.Json.Nodes;

namespace AMon.Quotas.Providers.Grok;

/// Why a Grok credential can't be used. Mirrors the macOS `GrokAuthError` cases.
public enum GrokAuthFailure
{
    None,
    /// No readable `auth.json` at all.
    NotLoggedIn,
    /// The file is there but carries no entry with a key (or is corrupt).
    InvalidAuth,
}

/// One entry of `~/.grok/auth.json`. Mutable because a token refresh rotates the fields in place
/// before they are merged back into the file.
public sealed class GrokAuthEntry
{
    public string? Key { get; set; }
    public string? RefreshToken { get; set; }
    public string? Refresh { get; set; }
    public string? IdToken { get; set; }
    public string? ExpiresAt { get; set; }
    public string? Expires { get; set; }
    public string? OidcClientId { get; set; }

    internal static GrokAuthEntry FromJson(JsonObject entry) => new()
    {
        Key = Text(entry, "key"),
        RefreshToken = Text(entry, "refresh_token"),
        Refresh = Text(entry, "refresh"),
        IdToken = Text(entry, "id_token"),
        ExpiresAt = Text(entry, "expires_at"),
        Expires = Text(entry, "expires"),
        OidcClientId = Text(entry, "oidc_client_id"),
    };

    private static string? Text(JsonObject entry, string name) =>
        entry[name] is JsonValue value && value.TryGetValue<string>(out var text) && !string.IsNullOrWhiteSpace(text)
            ? text.Trim()
            : null;
}

/// One candidate credential: the entry, its key inside the file, the current access token, and the
/// whole file as parsed, so a save can rebuild a file that vanished under us.
public sealed class GrokAuthState(JsonObject auth, string entryKey, GrokAuthEntry entry, string token)
{
    internal JsonObject Auth { get; } = auth;
    public string EntryKey { get; } = entryKey;
    public GrokAuthEntry Entry { get; } = entry;
    public string Token { get; set; } = token;
}

/// Reads (and rewrites) the credentials the Grok CLI leaves in `%USERPROFILE%\.grok\auth.json` — a
/// JSON object keyed by account entry, each entry holding an access key plus its refresh material.
public sealed class GrokAuthStore(IQuotaFileSystem files, IQuotaEnvironment environment, IQuotaClock clock)
{
    public const string DefaultClientId = "b1a00492-073a-47ea-816f-4c329264a828";
    public static readonly TimeSpan RefreshBuffer = TimeSpan.FromMinutes(5);

    public string AuthPath => environment.Home(".grok", "auth.json");

    /// Every entry carrying a non-empty key, in ordinal entry-key order so the chosen account is
    /// deterministic across refreshes.
    public IReadOnlyList<GrokAuthState> LoadAuthCandidates(out GrokAuthFailure failure)
    {
        failure = GrokAuthFailure.None;
        if (ReadAuthObject() is not { } auth)
        {
            failure = GrokAuthFailure.NotLoggedIn;
            return [];
        }

        var candidates = new List<GrokAuthState>();
        foreach (var entryKey in auth.Select(pair => pair.Key).OrderBy(key => key, StringComparer.Ordinal))
        {
            if (auth[entryKey] is not JsonObject entryObject)
                continue;
            var entry = GrokAuthEntry.FromJson(entryObject);
            if (entry.Key is not { } token)
                continue;
            candidates.Add(new GrokAuthState(auth, entryKey, entry, token));
        }

        if (candidates.Count == 0)
            failure = GrokAuthFailure.InvalidAuth;
        return candidates;
    }

    /// Merge the rotated fields back into `auth.json`, preserving every other account's entry and
    /// every field this port doesn't model. Returns false when the write could not be made safely.
    public bool Save(GrokAuthState state)
    {
        JsonObject auth;
        if (files.Exists(AuthPath))
        {
            // Refuse to rebuild a present-but-unreadable file from memory: that would silently drop
            // the other accounts' entries.
            if (ReadAuthObject() is not { } existing)
                return false;
            auth = existing;
        }
        else
        {
            auth = state.Auth.DeepClone().AsObject();
        }

        if (auth[state.EntryKey] is not JsonObject entryObject)
        {
            entryObject = new JsonObject();
            auth[state.EntryKey] = entryObject;
        }
        if (state.Entry.Key is { } accessKey)
            entryObject["key"] = accessKey;
        else
            entryObject.Remove("key");
        if (state.Entry.RefreshToken is { } refreshToken)
            entryObject["refresh_token"] = refreshToken;
        if (state.Entry.IdToken is { } idToken)
            entryObject["id_token"] = idToken;
        if (state.Entry.ExpiresAt is { } expiresAt)
            entryObject["expires_at"] = expiresAt;

        try
        {
            files.WriteText(AuthPath, Sorted(auth)!.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// True when either the entry's own expiry or the access token's JWT `exp` is inside the buffer.
    public bool NeedsRefresh(GrokAuthEntry entry, string token) =>
        IsWithinBuffer(EntryExpiresAt(entry)) || IsWithinBuffer(TokenExpiresAt(token));

    /// True only when an expiry is known and already past; an entry with no expiry is never expired.
    public bool IsExpired(GrokAuthEntry entry, string token) =>
        (TokenExpiresAt(token) ?? EntryExpiresAt(entry)) is { } expiresAt && clock.Now >= expiresAt;

    public string? RefreshTokenFor(GrokAuthEntry entry) => entry.RefreshToken ?? entry.Refresh;

    /// `oidc_client_id`, else the trailing `::`-delimited segment of the entry key, else the CLI's
    /// well-known public client id.
    public string ClientId(string entryKey, GrokAuthEntry entry)
    {
        if (entry.OidcClientId is { } configured)
            return configured;
        var segments = entryKey.Split("::", StringSplitOptions.None);
        var last = segments[^1].Trim();
        return last.Length > 0 ? last : DefaultClientId;
    }

    public DateTimeOffset? TokenExpiresAt(string token)
    {
        using var payload = QuotaJson.JwtPayload(token);
        return payload is null ? null : QuotaTime.FromEpochSeconds(QuotaJson.Number(payload.RootElement, "exp"));
    }

    private JsonObject? ReadAuthObject()
    {
        if (!files.Exists(AuthPath))
            return null;
        try
        {
            return JsonNode.Parse(files.ReadText(AuthPath)) as JsonObject;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    private DateTimeOffset? EntryExpiresAt(GrokAuthEntry entry) =>
        QuotaTime.ParseIso8601(entry.ExpiresAt) ?? QuotaTime.ParseIso8601(entry.Expires);

    private bool IsWithinBuffer(DateTimeOffset? expiresAt) =>
        expiresAt is { } value && value - clock.Now <= RefreshBuffer;

    /// Deterministic, key-sorted output so a rewritten file diffs cleanly (the macOS store uses
    /// `.sortedKeys` for the same reason).
    private static JsonNode? Sorted(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject source:
                {
                    var sorted = new JsonObject();
                    foreach (var (name, value) in source.OrderBy(pair => pair.Key, StringComparer.Ordinal))
                        sorted[name] = Sorted(value?.DeepClone());
                    return sorted;
                }
            case JsonArray source:
                {
                    var sorted = new JsonArray();
                    foreach (var item in source)
                        sorted.Add(Sorted(item?.DeepClone()));
                    return sorted;
                }
            default:
                return node?.DeepClone();
        }
    }
}
