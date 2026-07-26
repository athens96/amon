namespace AMon.Activity;

public sealed class LiveActivityService
{
    private readonly IReadOnlyList<ILiveSessionSource> _sources;
    private readonly TimeProvider _timeProvider;
    private readonly object _sessionsLock = new();
    private IReadOnlyList<LiveSession> _sessions = [];

    public LiveActivityService(
        IEnumerable<ILiveSessionSource> sources,
        TimeProvider? timeProvider = null,
        TimeSpan? pollInterval = null)
    {
        ArgumentNullException.ThrowIfNull(sources);
        _sources = sources.ToArray();
        _timeProvider = timeProvider ?? TimeProvider.System;
        PollInterval = pollInterval ?? TimeSpan.FromSeconds(5);
        if (PollInterval <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(pollInterval));
    }

    public TimeSpan PollInterval { get; }

    public IReadOnlyList<LiveSession> Sessions
    {
        get
        {
            lock (_sessionsLock)
                return _sessions;
        }
    }

    public event EventHandler<IReadOnlyList<LiveSession>>? SessionsChanged;

    public async Task<IReadOnlyList<LiveSession>> PollOnceAsync(
        CancellationToken cancellationToken = default)
    {
        var context = new LivePollContext(_timeProvider);
        var results = await Task.WhenAll(_sources.Select(source =>
            PollSourceSafelyAsync(source, context, cancellationToken)));
        var merged = results
            .SelectMany(static result => result)
            .GroupBy(static session => session.Identity, StringComparer.Ordinal)
            .Select(static group => group
                .OrderByDescending(session => session.UpdatedAt)
                .First())
            .OrderBy(static session => session.StartedAt)
            .ThenBy(static session => session.Provider, StringComparer.Ordinal)
            .ThenBy(static session => session.SessionId, StringComparer.Ordinal)
            .ToArray();

        var changed = false;
        lock (_sessionsLock)
        {
            if (!SessionsEqual(_sessions, merged))
            {
                _sessions = merged;
                changed = true;
            }
        }
        if (changed)
            NotifySessionsChanged(merged);
        return merged;
    }

    private static bool SessionsEqual(
        IReadOnlyList<LiveSession> left,
        IReadOnlyList<LiveSession> right)
    {
        if (left.Count != right.Count)
            return false;
        for (var index = 0; index < left.Count; index++)
        {
            var first = left[index];
            var second = right[index];
            if (!string.Equals(first.Provider, second.Provider, StringComparison.Ordinal)
                || !string.Equals(first.SessionId, second.SessionId, StringComparison.Ordinal)
                || !string.Equals(first.ProjectLabel, second.ProjectLabel, StringComparison.Ordinal)
                || !string.Equals(first.GitBranch, second.GitBranch, StringComparison.Ordinal)
                || !string.Equals(first.Status, second.Status, StringComparison.Ordinal)
                || !string.Equals(first.CurrentTask, second.CurrentTask, StringComparison.Ordinal)
                || !string.Equals(first.LastResult, second.LastResult, StringComparison.Ordinal)
                || !string.Equals(first.Model, second.Model, StringComparison.Ordinal)
                || first.Tokens != second.Tokens
                || first.StartedAt != second.StartedAt
                || first.UpdatedAt != second.UpdatedAt
                || !first.Agents.SequenceEqual(second.Agents))
                return false;
        }
        return true;
    }

    private void NotifySessionsChanged(IReadOnlyList<LiveSession> sessions)
    {
        var handlers = SessionsChanged;
        if (handlers is null)
            return;
        foreach (EventHandler<IReadOnlyList<LiveSession>> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, sessions);
            }
            catch
            {
                // A UI subscriber must not stop collection or suppress other subscribers.
            }
        }
    }

    private static async Task<IReadOnlyList<LiveSession>> PollSourceSafelyAsync(
        ILiveSessionSource source,
        LivePollContext context,
        CancellationToken cancellationToken)
    {
        try
        {
            return await source.PollAsync(context, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return [];
        }
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        await PollOnceAsync(cancellationToken);
        using var timer = new PeriodicTimer(PollInterval, _timeProvider);
        while (await timer.WaitForNextTickAsync(cancellationToken))
            await PollOnceAsync(cancellationToken);
    }
}
