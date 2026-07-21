using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace AMon;

public sealed class TokenUsage
{
    public long Input { get; set; }
    public long Output { get; set; }
    public long CacheRead { get; set; }
    public long CacheWrite { get; set; }
    public long Reasoning { get; set; }
    public long Total { get; set; }

    public void Add(TokenUsage other)
    {
        Input += other.Input;
        Output += other.Output;
        CacheRead += other.CacheRead;
        CacheWrite += other.CacheWrite;
        Reasoning += other.Reasoning;
        Total += other.Total;
    }

    public TokenUsage Clone() => (TokenUsage)MemberwiseClone();
}

public sealed class ToolSummary
{
    public string Tool { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public TokenUsage Usage { get; } = new();
    public TokenUsage Today { get; set; } = new();
    public Dictionary<string, TokenUsage> Daily { get; } = [];
    public Dictionary<string, Dictionary<string, TokenUsage>> DailyByModel { get; } = [];
    public Dictionary<string, Dictionary<string, double>> DailyCostByModel { get; } = [];
    public Dictionary<string, long> Models { get; } = [];
    public double CostUsd { get; set; }
    public int Sessions { get; set; }
    public DateTimeOffset? LastActivity { get; set; }
    public bool PathExists { get; set; } = true;
    public string Note { get; set; } = "";

    public void Add(DateTimeOffset timestamp, string model, TokenUsage usage, DateTimeOffset windowStart, double cost = 0)
    {
        Usage.Add(usage);
        CostUsd += cost;
        if (usage.Total > 0 && !string.IsNullOrWhiteSpace(model))
            Models[model] = Models.GetValueOrDefault(model) + usage.Total;
        if (LastActivity is null || timestamp > LastActivity) LastActivity = timestamp;
        if (timestamp < windowStart) return;
        var day = timestamp.LocalDateTime.ToString("yyyy-MM-dd");
        if (!Daily.TryGetValue(day, out var daily)) Daily[day] = daily = new TokenUsage();
        daily.Add(usage);
        if (!DailyByModel.TryGetValue(day, out var byModel)) DailyByModel[day] = byModel = [];
        if (!byModel.TryGetValue(model, out var modelUsage)) byModel[model] = modelUsage = new TokenUsage();
        modelUsage.Add(usage);
        if (cost != 0)
        {
            if (!DailyCostByModel.TryGetValue(day, out var costs)) DailyCostByModel[day] = costs = [];
            costs[model] = costs.GetValueOrDefault(model) + cost;
        }
    }
}

public sealed class SessionRecord
{
    [JsonPropertyName("provider")] public string Provider { get; set; } = "";
    [JsonPropertyName("session_id")] public string SessionId { get; set; } = "";
    [JsonPropertyName("project_label")] public string ProjectLabel { get; set; } = "";
    [JsonPropertyName("git_branch")] public string GitBranch { get; set; } = "";
    [JsonPropertyName("started_at")] public DateTimeOffset StartedAt { get; set; }
    [JsonPropertyName("ended_at")] public DateTimeOffset EndedAt { get; set; }
    [JsonPropertyName("prompts")] public List<string> Prompts { get; set; } = [];
    [JsonPropertyName("prompt_count")] public int PromptCount { get; set; }
    [JsonPropertyName("current_task")] public string CurrentTask { get; set; } = "";
    [JsonPropertyName("last_result")] public string LastResult { get; set; } = "";
    [JsonPropertyName("input_tokens")] public long InputTokens { get; set; }
    [JsonPropertyName("output_tokens")] public long OutputTokens { get; set; }
    [JsonPropertyName("cache_tokens")] public long CacheTokens { get; set; }
    [JsonPropertyName("total_tokens")] public long TotalTokens { get; set; }
    [JsonPropertyName("models")] public Dictionary<string, long> Models { get; set; } = [];
    [JsonPropertyName("agent_count")] public int AgentCount { get; set; }
    [JsonPropertyName("source_path")] public string SourcePath { get; set; } = "";
    [JsonIgnore] public string Id => $"{Provider}:{SessionId}";
}

public sealed class QuotaMetric
{
    public string Label { get; init; } = "";
    public double UsedPercent { get; init; }
    public DateTimeOffset? ResetsAt { get; init; }
    public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
    public string RemainingText => $"{RemainingPercent:0}% 남음";
    public string ResetText => FormatReset(ResetsAt);

    private static string FormatReset(DateTimeOffset? reset)
    {
        if (reset is null) return "";
        var left = reset.Value - DateTimeOffset.Now;
        if (left <= TimeSpan.Zero) return "곧 갱신";
        if (left < TimeSpan.FromHours(1)) return $"{Math.Max(1, (int)left.TotalMinutes)}분";
        if (left < TimeSpan.FromDays(1)) return $"{(int)left.TotalHours}시간";
        return $"{(int)left.TotalDays}일";
    }
}

public sealed class ProviderSnapshot
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Plan { get; set; } = "";
    public string Status { get; set; } = "";
    public ObservableCollection<QuotaMetric> Metrics { get; } = [];
}

public sealed class ToolRow
{
    public string Name { get; init; } = "";
    public string Today { get; init; } = "";
    public string Total { get; init; } = "";
}

public sealed class SessionRow
{
    public string Label { get; init; } = "";
    public string Provider { get; init; } = "";
    public string Time { get; init; } = "";
    public bool Active { get; init; }
}

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
}
