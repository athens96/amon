using System.Text.Json;

namespace AMon.Quotas.Providers.Copilot;

/// Where a candidate GitHub token was found. Only used for diagnostics — every source is tried in
/// order until one authenticates.
public enum CopilotTokenSource
{
    /// The OAuth token written by the Copilot editor plugins (VS Code / JetBrains / Neovim).
    EditorApp,
    /// `oauth_token` stored in the GitHub CLI's `hosts.yml` (file-based storage).
    GhConfig,
    /// The GitHub CLI token stored in Windows Credential Manager via go-keyring.
    GhCredentialManager,
}

/// A GitHub token already on the machine, usable against the Copilot usage endpoint.
public sealed record CopilotToken(string Value, CopilotTokenSource Source);

/// Reads a GitHub token that Copilot tooling already left on the machine — no login flow, no browser
/// cookies. Sources are tried prompt-free files first, Credential Manager last:
/// 1. Copilot editor config `%LOCALAPPDATA%\github-copilot\apps.json` (older `hosts.json`, plus the
///    POSIX-style `~/.config/github-copilot` the cross-platform plugins still use) — the OAuth token
///    the VS Code / JetBrains / Neovim Copilot plugins write.
/// 2. GitHub CLI `hosts.yml` `oauth_token` — present when `gh` stores the token in a file.
/// 3. GitHub CLI Credential Manager entry (target `gh:github.com`) — go-keyring-wrapped, used when
///    `gh` stores the token in the system keyring instead of the file.
public sealed class CopilotAuthStore(
    IQuotaFileSystem files,
    IQuotaEnvironment environment,
    IWindowsCredentialStore credentialStore)
{
    /// go-keyring's Windows backend keys generic credentials by `service:user` (service alone when
    /// the account is unknown).
    public const string GhCredentialService = "gh:github.com";

    public IReadOnlyList<string> EditorConfigPaths =>
    [
        environment.LocalAppData("github-copilot", "apps.json"),
        environment.LocalAppData("github-copilot", "hosts.json"),
        environment.Home(".config", "github-copilot", "apps.json"),
        environment.Home(".config", "github-copilot", "hosts.json"),
    ];

    public IReadOnlyList<string> GhHostsPaths
    {
        get
        {
            var paths = new List<string>();
            if (environment.Variable("GH_CONFIG_DIR") is { } configured)
                paths.Add(Path.Combine(Environment.ExpandEnvironmentVariables(configured), "hosts.yml"));
            paths.Add(environment.AppData("GitHub CLI", "hosts.yml"));
            paths.Add(environment.Home(".config", "gh", "hosts.yml"));
            return paths;
        }
    }

    /// Every candidate token — all `github.com*` entries from the editor config, then the gh file and
    /// Credential Manager. `apps.json` can hold both the old and the new Copilot app entries and some
    /// of them are expired, so the caller tries them in order until one authenticates.
    public IReadOnlyList<CopilotToken> LoadTokenCandidates()
    {
        var candidates = new List<CopilotToken>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        void Add(CopilotToken? candidate)
        {
            if (candidate is not null && seen.Add(candidate.Value))
                candidates.Add(candidate);
        }

        foreach (var path in EditorConfigPaths)
        {
            if (ReadTextOrNull(path) is not { } text)
                continue;
            foreach (var token in OAuthTokensFromEditorJson(text))
                Add(new CopilotToken(token, CopilotTokenSource.EditorApp));
        }

        Add(LoadFromGhConfig());
        Add(LoadFromCredentialManager());
        return candidates;
    }

    public CopilotToken? LoadFromGhConfig()
    {
        foreach (var path in GhHostsPaths)
        {
            if (ReadTextOrNull(path) is not { } text)
                continue;
            if (YamlValue(text, "oauth_token") is { } token)
                return new CopilotToken(token, CopilotTokenSource.GhConfig);
        }
        return null;
    }

    public CopilotToken? LoadFromCredentialManager() =>
        GoKeyring.Unwrap(ReadGhCredentialRaw()) is { } token
            ? new CopilotToken(token, CopilotTokenSource.GhCredentialManager)
            : null;

    /// `gh` stores its keyring item under the GitHub username as the account. Read it scoped to that
    /// account when it can be recovered from `hosts.yml`; otherwise fall back to the service-only target.
    private string? ReadGhCredentialRaw()
    {
        if (GhUsername() is { } account
            && credentialStore.ReadGenericCredential($"{GhCredentialService}:{account}") is { } scoped)
        {
            return scoped;
        }
        return credentialStore.ReadGenericCredential(GhCredentialService);
    }

    private string? GhUsername()
    {
        foreach (var path in GhHostsPaths)
        {
            if (ReadTextOrNull(path) is not { } text)
                continue;
            if (YamlValue(text, "user") is { } user)
                return user;
        }
        return null;
    }

    private string? ReadTextOrNull(string path)
    {
        if (!files.Exists(path))
            return null;
        try
        {
            return files.ReadText(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// Pull the github.com `oauth_token`s from the Copilot editor config. The file is a JSON object
    /// keyed by host — `"github.com"` (older `hosts.json`) or `"github.com:<appId>"` (newer
    /// `apps.json`) — each value an object carrying `oauth_token`. Only github.com entries are used:
    /// another host's token (e.g. GitHub Enterprise) must not be sent to api.github.com.
    ///
    /// Keys are ordered descending so the result is stable across processes — a newer GitHub app id
    /// (`Iv23…`) sorts later alphabetically, so descending puts the newest app entry first.
    public static IReadOnlyList<string> OAuthTokensFromEditorJson(string text)
    {
        try
        {
            using var document = QuotaJson.ParseObject(text);
            if (document is null)
                return [];

            var keys = new List<string>();
            foreach (var property in document.RootElement.EnumerateObject())
            {
                if (property.Name == "github.com" || property.Name.StartsWith("github.com:", StringComparison.Ordinal))
                    keys.Add(property.Name);
            }
            keys.Sort(static (left, right) => string.CompareOrdinal(right, left));

            var tokens = new List<string>();
            foreach (var key in keys)
            {
                var entry = document.RootElement.GetProperty(key);
                if (entry.ValueKind == JsonValueKind.Object && QuotaJson.String(entry, "oauth_token") is { } token)
                    tokens.Add(token);
            }
            return tokens;
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// Read an indented `key: value` from within a specific host block of the `hosts.yml` the GitHub
    /// CLI writes. `gh` keys each host block by a top-level (unindented) `<host>:` line; reading must
    /// be scoped to the `github.com` block, because a GitHub Enterprise block in the same file would
    /// otherwise let its `oauth_token` win and get sent to api.github.com (a guaranteed 401/403).
    /// `users:` (the nested map) doesn't match `user:` because the colon position differs.
    public static string? YamlValue(string text, string key, string host = "github.com")
    {
        var prefix = key + ":";
        var hostHeader = host + ":";
        var inHost = false;
        foreach (var line in text.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
        {
            // An unindented line starts a new top-level block (a host header or other root key); only
            // the github.com block's children should be read.
            if (!char.IsWhiteSpace(line[0]))
            {
                inHost = line.Trim().StartsWith(hostHeader, StringComparison.Ordinal);
                continue;
            }
            if (!inHost)
                continue;
            var trimmed = line.Trim();
            if (!trimmed.StartsWith(prefix, StringComparison.Ordinal))
                continue;
            var value = trimmed[prefix.Length..].Trim().Trim('"', '\'');
            return value.Length == 0 ? null : value;
        }
        return null;
    }
}
