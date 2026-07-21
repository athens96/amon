using Microsoft.Data.Sqlite;
using System.Text.Json;

namespace AMon;

public sealed class UsageStore
{
    private readonly string _path;
    public UsageStore(string directory) => _path = Path.Combine(directory, "usage.db");

    public void Save(IReadOnlyList<ToolSummary> summaries, IReadOnlyList<SessionRecord> sessions, AppConfig config)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        using var connection = new SqliteConnection($"Data Source={_path}");
        connection.Open();
        Execute(connection, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;" + Schema);
        using var transaction = connection.BeginTransaction();
        Meta(connection, transaction, "schema_version", "1");
        Meta(connection, transaction, "generated_at", DateTimeOffset.UtcNow.ToString("O"));
        Meta(connection, transaction, "machine", Environment.MachineName);
        Meta(connection, transaction, "app_version", "0.3.30");
        Meta(connection, transaction, "device_id", config.DeviceId);
        var window = DateTime.Today.AddDays(-29).ToString("yyyy-MM-dd");
        foreach (var summary in summaries)
        {
            Command(connection, transaction, "DELETE FROM usage_daily WHERE tool=$tool AND date >= $date", ("$tool", summary.Tool), ("$date", window)).ExecuteNonQuery();
            foreach (var (date, models) in summary.DailyByModel)
                foreach (var (model, usage) in models)
                {
                    var cost = summary.DailyCostByModel.TryGetValue(date, out var costs) && costs.TryGetValue(model, out var value) ? value : (double?)null;
                    Command(connection, transaction, "INSERT INTO usage_daily(date,tool,model,input,output,cache_read,cache_write,reasoning,total,cost_usd) VALUES($date,$tool,$model,$input,$output,$read,$write,$reasoning,$total,$cost)",
                        ("$date", date), ("$tool", summary.Tool), ("$model", model), ("$input", usage.Input), ("$output", usage.Output), ("$read", usage.CacheRead), ("$write", usage.CacheWrite), ("$reasoning", usage.Reasoning), ("$total", usage.Total), ("$cost", cost)).ExecuteNonQuery();
                }
            var u = summary.Usage;
            Command(connection, transaction, "INSERT INTO tool_totals(tool,input,output,cache_read,cache_write,reasoning,total,cost_usd,sessions,last_activity,models_json,path_exists,note) VALUES($tool,$input,$output,$read,$write,$reasoning,$total,$cost,$sessions,$last,$models,$exists,$note) ON CONFLICT(tool) DO UPDATE SET input=excluded.input,output=excluded.output,cache_read=excluded.cache_read,cache_write=excluded.cache_write,reasoning=excluded.reasoning,total=excluded.total,cost_usd=excluded.cost_usd,sessions=excluded.sessions,last_activity=excluded.last_activity,models_json=excluded.models_json,path_exists=excluded.path_exists,note=excluded.note",
                ("$tool", summary.Tool), ("$input", u.Input), ("$output", u.Output), ("$read", u.CacheRead), ("$write", u.CacheWrite), ("$reasoning", u.Reasoning), ("$total", u.Total), ("$cost", summary.CostUsd == 0 ? null : summary.CostUsd), ("$sessions", summary.Sessions), ("$last", summary.LastActivity?.UtcDateTime.ToString("O")), ("$models", JsonSerializer.Serialize(summary.Models)), ("$exists", summary.PathExists ? 1 : 0), ("$note", summary.Note.Length == 0 ? null : summary.Note)).ExecuteNonQuery();
        }
        foreach (var session in sessions)
            Command(connection, transaction, "INSERT INTO sessions(id,tool,session_id,project,git_branch,started_at,ended_at,input,output,cache_read,cache_write,total,cost_usd,models_json,prompt_count,first_prompt,agent_count) VALUES($id,$tool,$sid,$project,$branch,$start,$end,$input,$output,$cache,0,$total,NULL,$models,$count,$prompt,$agents) ON CONFLICT(id) DO UPDATE SET project=excluded.project,git_branch=excluded.git_branch,started_at=excluded.started_at,ended_at=excluded.ended_at,input=excluded.input,output=excluded.output,cache_read=excluded.cache_read,total=excluded.total,models_json=excluded.models_json,prompt_count=excluded.prompt_count,first_prompt=excluded.first_prompt,agent_count=excluded.agent_count",
                ("$id", session.Id), ("$tool", session.Provider == "claude" ? "claudeCode" : session.Provider), ("$sid", session.SessionId), ("$project", session.ProjectLabel), ("$branch", session.GitBranch), ("$start", session.StartedAt.UtcDateTime.ToString("O")), ("$end", session.EndedAt.UtcDateTime.ToString("O")), ("$input", session.InputTokens), ("$output", session.OutputTokens), ("$cache", session.CacheTokens), ("$total", session.TotalTokens), ("$models", JsonSerializer.Serialize(session.Models.Keys)), ("$count", session.PromptCount), ("$prompt", session.Prompts.FirstOrDefault() ?? session.CurrentTask), ("$agents", session.AgentCount)).ExecuteNonQuery();
        Command(connection, transaction, "DELETE FROM sessions WHERE id IN (SELECT id FROM sessions ORDER BY ended_at DESC LIMIT -1 OFFSET 2000)").ExecuteNonQuery();
        transaction.Commit();
    }

    private static void Meta(SqliteConnection connection, SqliteTransaction transaction, string key, string value) => Command(connection, transaction, "INSERT INTO meta(key,value) VALUES($key,$value) ON CONFLICT(key) DO UPDATE SET value=excluded.value", ("$key", key), ("$value", value)).ExecuteNonQuery();
    private static void Execute(SqliteConnection connection, string sql) { using var command = connection.CreateCommand(); command.CommandText = sql; command.ExecuteNonQuery(); }
    private static SqliteCommand Command(SqliteConnection connection, SqliteTransaction transaction, string sql, params (string Name, object? Value)[] values)
    {
        var command = connection.CreateCommand(); command.Transaction = transaction; command.CommandText = sql;
        foreach (var (name, value) in values) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return command;
    }

    private const string Schema = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS usage_daily(date TEXT NOT NULL,tool TEXT NOT NULL,model TEXT NOT NULL DEFAULT '',input INTEGER NOT NULL DEFAULT 0,output INTEGER NOT NULL DEFAULT 0,cache_read INTEGER NOT NULL DEFAULT 0,cache_write INTEGER NOT NULL DEFAULT 0,reasoning INTEGER NOT NULL DEFAULT 0,total INTEGER NOT NULL DEFAULT 0,cost_usd REAL,PRIMARY KEY(date,tool,model));
CREATE TABLE IF NOT EXISTS tool_totals(tool TEXT PRIMARY KEY,input INTEGER NOT NULL DEFAULT 0,output INTEGER NOT NULL DEFAULT 0,cache_read INTEGER NOT NULL DEFAULT 0,cache_write INTEGER NOT NULL DEFAULT 0,reasoning INTEGER NOT NULL DEFAULT 0,total INTEGER NOT NULL DEFAULT 0,cost_usd REAL,sessions INTEGER NOT NULL DEFAULT 0,last_activity TEXT,models_json TEXT NOT NULL DEFAULT '{}',path_exists INTEGER NOT NULL DEFAULT 0,note TEXT);
CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,tool TEXT NOT NULL,session_id TEXT NOT NULL,project TEXT,git_branch TEXT,started_at TEXT,ended_at TEXT,input INTEGER NOT NULL DEFAULT 0,output INTEGER NOT NULL DEFAULT 0,cache_read INTEGER NOT NULL DEFAULT 0,cache_write INTEGER NOT NULL DEFAULT 0,total INTEGER NOT NULL DEFAULT 0,cost_usd REAL,models_json TEXT NOT NULL DEFAULT '[]',prompt_count INTEGER NOT NULL DEFAULT 0,first_prompt TEXT,agent_count INTEGER NOT NULL DEFAULT 0);
""";
}
