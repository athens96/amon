namespace AMon.Quotas.Providers.ZAI;

/// Where the key in use came from. The config file wins, so a saved key overrides a stale env var.
public enum ZaiKeySource
{
    ConfigFile,
    Environment,
}

public sealed record ZaiAuth(string ApiKey, ZaiKeySource Source);

/// Reads a Z.ai (Zhipu AI) API key the user has already placed on the machine — a small config file
/// or an environment variable. `ZAI_API_KEY` is current; `GLM_API_KEY` is the legacy Zhipu name some
/// users still export. Key management (save/delete) is not ported yet.
public sealed class ZaiAuthStore(IQuotaFileSystem files, IQuotaEnvironment environment)
{
    public static readonly string[] EnvironmentNames = ["ZAI_API_KEY", "GLM_API_KEY"];

    /// Config files checked in order; the first readable key wins.
    public IReadOnlyList<string> ConfigPaths =>
    [
        environment.Home(".config", "openusage", "zai.json"),
        environment.Home(".config", "zai", "key.json"),
        environment.AppData("zai", "key.json"),
    ];

    /// Config file first, environment second — the config file is the path a user edits to rotate
    /// the key, so it must win over a stale `ZAI_API_KEY`.
    public ZaiAuth? LoadApiKey()
    {
        if (KeyFromConfigFile() is { } configured)
            return new ZaiAuth(configured, ZaiKeySource.ConfigFile);
        if (KeyFromEnvironment() is { } exported)
            return new ZaiAuth(exported, ZaiKeySource.Environment);
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
