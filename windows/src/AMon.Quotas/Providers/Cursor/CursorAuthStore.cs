using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace AMon.Quotas.Providers.Cursor;

public sealed record CursorAuthTokens(string? AccessToken, string? RefreshToken);

/// Cursor's `state.vscdb` (`ItemTable`) holds `cursorAuth/accessToken` and `cursorAuth/refreshToken`.
/// Reads are read-only; a refreshed access token is written back best-effort so the next cycle
/// reuses it, exactly as the previous in-app implementation did.
public interface ICursorStateStore
{
    bool Exists { get; }
    Task<CursorAuthTokens> ReadTokensAsync(CancellationToken cancellationToken);
    Task TryPersistAccessTokenAsync(string accessToken, CancellationToken cancellationToken);
}

public sealed class CursorStateStore(IQuotaEnvironment environment, IQuotaFileSystem files) : ICursorStateStore
{
    public string DatabasePath => environment.AppData("Cursor", "User", "globalStorage", "state.vscdb");

    public bool Exists => files.Exists(DatabasePath);

    public async Task<CursorAuthTokens> ReadTokensAsync(CancellationToken cancellationToken)
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Shared,
        };
        await using var connection = new SqliteConnection(builder.ToString());
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT key, value
            FROM ItemTable
            WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/refreshToken');
            """;
        string? accessToken = null;
        string? refreshToken = null;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var key = reader.GetString(0);
            var value = DecodeStateValue(reader.IsDBNull(1) ? null : reader.GetString(1));
            if (key == "cursorAuth/accessToken")
                accessToken = value;
            else if (key == "cursorAuth/refreshToken")
                refreshToken = value;
        }
        return new CursorAuthTokens(accessToken, refreshToken);
    }

    public async Task TryPersistAccessTokenAsync(string accessToken, CancellationToken cancellationToken)
    {
        try
        {
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = DatabasePath,
                Mode = SqliteOpenMode.ReadWrite,
                Cache = SqliteCacheMode.Shared,
            };
            await using var connection = new SqliteConnection(builder.ToString());
            await connection.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText = """
                UPDATE ItemTable
                SET value = $value
                WHERE key = 'cursorAuth/accessToken';
                """;
            command.Parameters.AddWithValue("$value", JsonSerializer.Serialize(accessToken));
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (SqliteException)
        {
            // The refreshed token still works for this process if Cursor has its DB locked.
        }
    }

    /// Values are stored as JSON strings (`"eyJ…"`); a bare value is accepted as-is.
    internal static string? DecodeStateValue(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;
        try
        {
            return JsonSerializer.Deserialize<string>(value) ?? value;
        }
        catch (JsonException)
        {
            return value;
        }
    }
}
