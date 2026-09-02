using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace AMon.Quotas.Providers.Devin;

public enum DevinAuthSource
{
    /// `windsurf_api_key` from the `devin` CLI's `credentials.toml`.
    CredentialsFile,
    /// `apiKey` from the Devin desktop app's `state.vscdb` global storage.
    AppState,
}

public sealed record DevinAuth(string ApiKey, string? ApiServerUrl, DevinAuthSource Source);

/// Reads the Devin app's stored auth blob out of its VS Code-style `state.vscdb`. Behind an
/// interface so the auth store is testable without a real SQLite file.
public interface IDevinStateReader
{
    /// The `windsurfAuthStatus` value from the app's key/value table; `null` when the database is
    /// missing, locked, or has no such row.
    string? ReadAuthStatus(string databasePath);
}

public sealed class SqliteDevinStateReader : IDevinStateReader
{
    public const string Query = "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1";

    public string? ReadAuthStatus(string databasePath)
    {
        if (!File.Exists(databasePath))
            return null;
        try
        {
            var connectionString = new SqliteConnectionStringBuilder
            {
                DataSource = databasePath,
                Mode = SqliteOpenMode.ReadOnly,
            }.ToString();
            using var connection = new SqliteConnection(connectionString);
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = Query;
            return command.ExecuteScalar() switch
            {
                string text => text,
                byte[] bytes => Encoding.UTF8.GetString(bytes),
                _ => null,
            };
        }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}

/// Two prompt-free sources for the Devin API key: the `devin` CLI's credentials file, then the
/// desktop app's stored auth. Neither triggers a login flow.
public sealed class DevinAuthStore(IQuotaFileSystem files, IQuotaEnvironment environment, IDevinStateReader stateReader)
{
    public const string DefaultApiServerUrl = "https://server.codeium.com";

    public IReadOnlyList<string> CredentialsPaths =>
    [
        environment.LocalAppData("devin", "credentials.toml"),
        environment.AppData("devin", "credentials.toml"),
        environment.Home(".local", "share", "devin", "credentials.toml"),
    ];

    public string StateDatabasePath => environment.AppData("Devin", "User", "globalStorage", "state.vscdb");

    public DevinAuth? LoadCredentialsFile()
    {
        foreach (var path in CredentialsPaths)
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
            if (ReadTomlString(text, "windsurf_api_key") is not { } apiKey)
                continue;
            return new DevinAuth(
                apiKey,
                CleanApiServerUrl(ReadTomlString(text, "api_server_url")),
                DevinAuthSource.CredentialsFile);
        }
        return null;
    }

    public DevinAuth? LoadAppAuth()
    {
        try
        {
            using var document = QuotaJson.ParseObject(stateReader.ReadAuthStatus(StateDatabasePath));
            if (document is null || QuotaJson.String(document.RootElement, "apiKey") is not { } apiKey)
                return null;
            return new DevinAuth(apiKey, null, DevinAuthSource.AppState);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public string EffectiveApiServerUrl(DevinAuth auth) => auth.ApiServerUrl ?? DefaultApiServerUrl;

    /// Only an `https://` override is honored, with trailing slashes dropped for clean path joining.
    public static string? CleanApiServerUrl(string? value)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrEmpty(trimmed) || !trimmed.StartsWith("https://", StringComparison.Ordinal))
            return null;
        var withoutTrailingSlashes = trimmed.TrimEnd('/');
        // A syntactically broken override must degrade to "unavailable" (as the Swift client does),
        // never throw out of the request builder.
        if (!Uri.TryCreate(withoutTrailingSlashes, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrEmpty(uri.Host))
            return null;
        return withoutTrailingSlashes;
    }

    /// A flat `key = value` read over the credentials TOML: quoted values are read up to their closing
    /// quote, unquoted values are truncated at a `#` comment.
    public static string? ReadTomlString(string text, string key)
    {
        foreach (var line in text.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Split('=', 2);
            if (parts.Length != 2 || parts[0].Trim() != key)
                continue;

            var value = parts[1].Trim();
            if (value.Length == 0)
                return null;

            if (value[0] is '"' or '\'')
                return ReadQuotedTomlString(value);

            var comment = value.IndexOf('#');
            if (comment >= 0)
                value = value[..comment].Trim();
            return value.Length == 0 ? null : value;
        }
        return null;
    }

    private static string? ReadQuotedTomlString(string value)
    {
        var quote = value[0];
        var output = new StringBuilder();
        char? previous = null;
        for (var index = 1; index < value.Length; index++)
        {
            var character = value[index];
            if (character == quote && previous != '\\')
            {
                var trimmed = output.ToString().Trim();
                return trimmed.Length == 0 ? null : trimmed;
            }
            output.Append(character);
            previous = character;
        }
        return null;
    }
}
