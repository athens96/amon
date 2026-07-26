namespace AMon.Activity;

public enum LiveTokenScope
{
    Unavailable,
    LatestMessage,
    SessionCumulative,
    Estimated
}

public sealed record LiveTokenSnapshot(
    long? InputTokens,
    long? OutputTokens,
    long? CacheReadTokens,
    long? CacheWriteTokens,
    long? ReasoningTokens,
    long? TotalTokens,
    LiveTokenScope Scope)
{
    public static LiveTokenSnapshot Unavailable { get; } =
        new(null, null, null, null, null, null, LiveTokenScope.Unavailable);
}

public sealed record LiveAgent(
    string ToolUseId,
    string AgentType,
    string Description,
    DateTimeOffset StartedAt);

public sealed record LiveSession(
    string Provider,
    string SessionId,
    string ProjectLabel,
    string? GitBranch,
    string Status,
    IReadOnlyList<LiveAgent> Agents,
    string? CurrentTask,
    string? LastResult,
    string? Model,
    LiveTokenSnapshot Tokens,
    DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt)
{
    public string Identity => $"{Provider}:{SessionId}";
}

public sealed record LivePollContext(TimeProvider TimeProvider)
{
    public DateTimeOffset Now => TimeProvider.GetUtcNow();
}

public interface ILiveSessionSource
{
    string Provider { get; }

    Task<IReadOnlyList<LiveSession>> PollAsync(
        LivePollContext context,
        CancellationToken cancellationToken = default);
}
