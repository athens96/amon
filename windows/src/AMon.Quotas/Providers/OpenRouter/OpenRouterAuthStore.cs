namespace AMon.Quotas.Providers.OpenRouter;

/// Where the key in use came from. The config file wins, so a saved key overrides a stale env var.
public enum OpenRouterKeySource
{
    ConfigFile,
    Environment,
}

public sealed record OpenRouterAuth(string ApiKey, OpenRouterKeySource Source);

/// Reads an OpenRouter API key the user has already placed on the machine. OpenRouter has no
/// companion CLI that stashes a credential in a known spot, so the key comes from a small config
/// file or an environment variable. Key management (save/delete) is not ported yet.
public sealed class OpenRouterAuthStore(IQuotaFileSystem files, IQuotaEnvironment environment)
{
    /// Environment variables checked in order. `OPENROUTER_API_KEY` is the de-facto standard.
    public static readonly string[] EnvironmentNames = ["OPENROUTER_API_KEY", "OPENROUTER_KEY"];

    /// Config files checked in order; the first readable key wins.
    public IReadOnlyList<string> ConfigPaths =>
    [
        environment.Home(".config", "openusage", "openrouter.json"),
        environment.Home(".config", "openrouter", "key.json"),
        environment.AppData("openrouter", "key.json"),
    ];

    /// Config file first, environment second — the config file is the path a user edits to rotate
    /// the key, so it must win over a stale `OPENROUTER_API_KEY`.
    public OpenRouterAuth? LoadApiKey()
    {
        if (KeyFromConfigFile() is { } configured)
            return new OpenRouterAuth(configured, OpenRouterKeySource.ConfigFile);
        if (KeyFromEnvironment() is { } exported)
            return new OpenRouterAuth(exported, OpenRouterKeySource.Environment);
        return null;
    }

    /// A JSON object with `apiKey` / `api_key` / `key`, or a plain-text file holding only the key.
    public static string? KeyFromConfigText(string text)
    {
        using var document = QuotaJson.ParseObject(text);
        if (document is not null)
            return QuotaJson.FirstString(document.RootElement, "apiKey", "api_key", "key");

        var trimmed = text.Trim();
        return trimmed.Length == 0 || trimmed.Contains('{') ? null : trimmed;
    }

    private string? KeyFromEnvironment()
    {
        foreach (var name in EnvironmentNames)
        {
            if (environment.Variable(name)?.Trim() is { Length: > 0 } value)
                return value;
        }
        return null;
    }

    private string? KeyFromConfigFile()
    {
        foreach (var path in ConfigPaths)
        {
            if (!files.Exists(path))
                continue;
            string text;
            try
            {
                text = files.ReadText(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            if (KeyFromConfigText(text) is { } key)
                return key;
        }
        return null;
    }
}
