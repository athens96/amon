using System.Text.Json;

namespace AMon.Quotas.Providers.Codex;

public sealed record CodexCredentials(string AccessToken, string? AccountId);

/// Reads the OAuth tokens the Codex CLI leaves in `auth.json` under `CODEX_HOME`, `%USERPROFILE%\.codex`,
/// or `%USERPROFILE%\.config\codex`. API-key-only accounts have no `tokens` object and cannot be metered.
public sealed class CodexAuthStore(IQuotaFileSystem files, IQuotaEnvironment environment)
{
    public IReadOnlyList<string> CandidatePaths
    {
        get
        {
            var paths = new List<string>();
            var configured = environment.Variable("CODEX_HOME");
            if (!string.IsNullOrWhiteSpace(configured))
                paths.Add(Path.Combine(Environment.ExpandEnvironmentVariables(configured), "auth.json"));
            paths.Add(environment.Home(".codex", "auth.json"));
            paths.Add(environment.Home(".config", "codex", "auth.json"));
            return paths;
        }
    }

    public bool HasAuthFile => CandidatePaths.Any(files.Exists);

    public CodexCredentials? Load()
    {
        foreach (var path in CandidatePaths)
        {
            if (!files.Exists(path))
                continue;
            try
            {
                using var document = QuotaJson.ParseObject(files.ReadText(path));
                if (document is null || QuotaJson.ObjectProperty(document.RootElement, "tokens") is not { } tokens)
                    continue;
                var token = QuotaJson.String(tokens, "access_token");
                if (token is not null)
                    return new CodexCredentials(token, QuotaJson.String(tokens, "account_id"));
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
            {
                // Unreadable file: try the next candidate.
            }
        }
        return null;
    }
}
