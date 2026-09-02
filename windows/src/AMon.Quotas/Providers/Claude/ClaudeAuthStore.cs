using System.Text.Json;

namespace AMon.Quotas.Providers.Claude;

public sealed record ClaudeCredentials(string AccessToken, string? SubscriptionType);

/// Reads the OAuth token Claude Code leaves in `.credentials.json` under `%USERPROFILE%\.claude`
/// (or `CLAUDE_CONFIG_DIR`). No keychain on Windows: the file is the only source.
public sealed class ClaudeAuthStore(IQuotaFileSystem files, IQuotaEnvironment environment)
{
    public string CredentialsPath
    {
        get
        {
            var configured = environment.Variable("CLAUDE_CONFIG_DIR");
            var home = string.IsNullOrWhiteSpace(configured)
                ? environment.Home(".claude")
                : Environment.ExpandEnvironmentVariables(configured);
            return Path.Combine(home, ".credentials.json");
        }
    }

    public bool HasCredentialsFile => files.Exists(CredentialsPath);

    public ClaudeCredentials? Load()
    {
        if (!files.Exists(CredentialsPath))
            return null;
        try
        {
            using var document = QuotaJson.ParseObject(files.ReadText(CredentialsPath));
            if (document is null || QuotaJson.ObjectProperty(document.RootElement, "claudeAiOauth") is not { } oauth)
                return null;
            var token = QuotaJson.String(oauth, "accessToken");
            return token is null ? null : new ClaudeCredentials(token, QuotaJson.String(oauth, "subscriptionType"));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }
}
