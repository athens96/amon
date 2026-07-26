using System.Globalization;
using System.Text.Json;
using AMon.Core;
using Microsoft.Data.Sqlite;

namespace AMon.LocalData;

public sealed class UsageDatabase
{
    private const int SchemaVersion = 1;
    private readonly string _path;

    public UsageDatabase(string path) => _path = path;

    private string ConnectionString(string path) =>
        new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString();

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path) ?? ".");
        await using var connection = new SqliteConnection(ConnectionString(_path));
        await connection.OpenAsync(cancellationToken);
        await ConfigureConnectionAsync(connection, cancellationToken);
        await ExecuteSchemaAsync(connection, includePrivateTables: true, cancellationToken);
    }

    public async Task SaveAsync(
        IEnumerable<ToolSummary> summaries,
        UsageDatabaseMetadata metadata,
        CancellationToken cancellationToken = default)
    {
        await InitializeAsync(cancellationToken);
        await using var connection = new SqliteConnection(ConnectionString(_path));
        await connection.OpenAsync(cancellationToken);
        await ConfigureConnectionAsync(connection, cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
        var refreshWindowStart = DateOnly
            .FromDateTime(metadata.GeneratedAt.LocalDateTime)
            .AddDays(-29)
            .ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

        foreach (var pair in new Dictionary<string, string>
        {
            ["schema_version"] = SchemaVersion.ToString(CultureInfo.InvariantCulture),
            ["machine"] = metadata.Machine,
            ["app_version"] = metadata.AppVersion,
            ["device_id"] = metadata.DeviceId,
            ["generated_at"] = metadata.GeneratedAt.ToString("O", CultureInfo.InvariantCulture)
        })
        {
            await using var meta = connection.CreateCommand();
            meta.Transaction = (SqliteTransaction)transaction;
            meta.CommandText = "INSERT OR REPLACE INTO meta(key,value) VALUES($key,$value)";
            meta.Parameters.AddWithValue("$key", pair.Key);
            meta.Parameters.AddWithValue("$value", pair.Value);
            await meta.ExecuteNonQueryAsync(cancellationToken);
        }

        foreach (var summary in summaries)
        {
            if (!summary.ScanSucceeded)
                continue;

            await using (var clear = connection.CreateCommand())
            {
                clear.Transaction = (SqliteTransaction)transaction;
                clear.CommandText = "DELETE FROM usage_daily WHERE tool=$tool AND date >= $window_start";
                clear.Parameters.AddWithValue("$tool", summary.Tool);
                clear.Parameters.AddWithValue("$window_start", refreshWindowStart);
                await clear.ExecuteNonQueryAsync(cancellationToken);
            }

            foreach (var day in summary.Daily)
            {
                await using var insert = connection.CreateCommand();
                insert.Transaction = (SqliteTransaction)transaction;
                insert.CommandText = """
                    INSERT INTO usage_daily(
                      date,tool,model,input,output,cache_read,
                      cache_write,reasoning,total,cost_usd)
                    VALUES($day,$tool,$model,$input,$output,$read,$write,$reasoning,$total,$cost)
                    """;
                insert.Parameters.AddWithValue("$day", day.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
                insert.Parameters.AddWithValue("$tool", summary.Tool);
                insert.Parameters.AddWithValue("$model", day.Model);
                insert.Parameters.AddWithValue("$input", day.Usage.InputTokens);
                insert.Parameters.AddWithValue("$output", day.Usage.OutputTokens);
                insert.Parameters.AddWithValue("$read", day.Usage.CacheReadTokens);
                insert.Parameters.AddWithValue("$write", day.Usage.CacheWriteTokens);
                insert.Parameters.AddWithValue("$reasoning", day.Usage.ReasoningTokens);
                insert.Parameters.AddWithValue("$total", day.Usage.TotalTokens);
                insert.Parameters.AddWithValue("$cost", day.CostUsd);
                await insert.ExecuteNonQueryAsync(cancellationToken);
            }

            await using var total = connection.CreateCommand();
            total.Transaction = (SqliteTransaction)transaction;
            total.CommandText = """
                INSERT OR REPLACE INTO tool_totals(
                  tool,input,output,cache_read,cache_write,reasoning,total,cost_usd,
                  sessions,last_activity,models_json,path_exists,note)
                VALUES($tool,$input,$output,$read,$write,$reasoning,$total,$cost,
                  $sessions,$activity,$models,$path,$note)
                """;
            total.Parameters.AddWithValue("$tool", summary.Tool);
            total.Parameters.AddWithValue("$input", summary.Usage.InputTokens);
            total.Parameters.AddWithValue("$output", summary.Usage.OutputTokens);
            total.Parameters.AddWithValue("$read", summary.Usage.CacheReadTokens);
            total.Parameters.AddWithValue("$write", summary.Usage.CacheWriteTokens);
            total.Parameters.AddWithValue("$reasoning", summary.Usage.ReasoningTokens);
            total.Parameters.AddWithValue("$total", summary.Usage.TotalTokens);
            total.Parameters.AddWithValue("$cost", summary.CostUsd);
            total.Parameters.AddWithValue("$sessions", summary.Sessions);
            total.Parameters.AddWithValue("$activity", summary.LastActivity?.ToString("O") ?? string.Empty);
            total.Parameters.AddWithValue("$models", JsonSerializer.Serialize(summary.ModelTotals));
            total.Parameters.AddWithValue("$path", summary.PathExists ? 1 : 0);
            total.Parameters.AddWithValue("$note", (object?)summary.Note ?? DBNull.Value);
            await total.ExecuteNonQueryAsync(cancellationToken);
        }

        await transaction.CommitAsync(cancellationToken);
    }

    public async Task CreateUploadSnapshotAsync(string destination, CancellationToken cancellationToken = default)
    {
        await InitializeAsync(cancellationToken);
        var directory = Path.GetDirectoryName(destination) ?? ".";
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(destination)}.{Guid.NewGuid():N}.tmp");

        try
        {
            await using var source = new SqliteConnection(ConnectionString(_path));
            await using var target = new SqliteConnection(ConnectionString(temporaryPath));
            await source.OpenAsync(cancellationToken);
            await target.OpenAsync(cancellationToken);
            await ConfigureConnectionAsync(source, cancellationToken);
            await ConfigureConnectionAsync(target, cancellationToken);
            await ExecuteSchemaAsync(target, includePrivateTables: false, cancellationToken);

            await using var sourceTransaction = await source.BeginTransactionAsync(cancellationToken);
            await using var targetTransaction = await target.BeginTransactionAsync(cancellationToken);
            foreach (var table in new[] { "meta", "usage_daily" })
                await CopyTableAsync(
                    source,
                    target,
                    table,
                    (SqliteTransaction)sourceTransaction,
                    (SqliteTransaction)targetTransaction,
                    cancellationToken);
            await targetTransaction.CommitAsync(cancellationToken);
            await sourceTransaction.CommitAsync(cancellationToken);

            await target.CloseAsync();
            if (File.Exists(destination))
                File.Replace(temporaryPath, destination, null, ignoreMetadataErrors: true);
            else
                File.Move(temporaryPath, destination);
        }
        finally
        {
            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);
        }
    }

    private static async Task CopyTableAsync(
        SqliteConnection source,
        SqliteConnection target,
        string table,
        SqliteTransaction sourceTransaction,
        SqliteTransaction targetTransaction,
        CancellationToken cancellationToken)
    {
        await using var read = source.CreateCommand();
        read.Transaction = sourceTransaction;
        read.CommandText = $"SELECT * FROM {table}";
        await using var reader = await read.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var parameters = Enumerable.Range(0, reader.FieldCount).Select(i => $"$p{i}").ToArray();
            await using var write = target.CreateCommand();
            write.Transaction = targetTransaction;
            write.CommandText = $"INSERT INTO {table} VALUES({string.Join(',', parameters)})";
            for (var i = 0; i < reader.FieldCount; i++)
                write.Parameters.AddWithValue(parameters[i], reader.IsDBNull(i) ? DBNull.Value : reader.GetValue(i));
            await write.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task ConfigureConnectionAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA busy_timeout=5000;";
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task ExecuteSchemaAsync(
        SqliteConnection connection,
        bool includePrivateTables,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = $"""
            PRAGMA user_version={SchemaVersion};
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS usage_daily(
              date TEXT NOT NULL, tool TEXT NOT NULL, model TEXT NOT NULL DEFAULT '',
              input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
              cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
              reasoning INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0,
              cost_usd REAL, PRIMARY KEY(date,tool,model));
            {(includePrivateTables ? """
            CREATE TABLE IF NOT EXISTS tool_totals(
              tool TEXT PRIMARY KEY,
              input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
              cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
              reasoning INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0,
              cost_usd REAL, sessions INTEGER NOT NULL DEFAULT 0,
              last_activity TEXT, models_json TEXT NOT NULL DEFAULT '{}',
              path_exists INTEGER NOT NULL DEFAULT 0, note TEXT);
            CREATE TABLE IF NOT EXISTS sessions(
              id TEXT PRIMARY KEY, tool TEXT NOT NULL, session_id TEXT NOT NULL,
              project TEXT, git_branch TEXT, started_at TEXT, ended_at TEXT,
              input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
              cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
              total INTEGER NOT NULL DEFAULT 0, cost_usd REAL,
              models_json TEXT NOT NULL DEFAULT '[]',
              prompt_count INTEGER NOT NULL DEFAULT 0, first_prompt TEXT,
              agent_count INTEGER NOT NULL DEFAULT 0);
            """ : string.Empty)}
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
