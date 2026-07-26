using Xunit;

namespace AMon.Activity.Tests;

public sealed class LiveActivityServiceTests
{
    [Fact]
    public async Task Merge_deduplicates_by_identity_keeps_newest_and_sorts_stably()
    {
        var now = DateTimeOffset.UtcNow;
        var older = Session("codex", "same", now.AddMinutes(-2), now.AddSeconds(-2));
        var newer = Session("codex", "same", now.AddMinutes(-2), now);
        var first = Session("claude", "first", now.AddMinutes(-3), now);
        var service = new LiveActivityService(
            [new FakeSource("one", [older, first]), new FakeSource("two", [newer])]);

        var result = await service.PollOnceAsync();

        Assert.Equal(2, result.Count);
        Assert.Equal("claude:first", result[0].Identity);
        Assert.Equal(now, result[1].UpdatedAt);
        Assert.Equal(TimeSpan.FromSeconds(5), service.PollInterval);
    }

    [Fact]
    public async Task RunAsync_polls_repeatedly_and_honors_cancellation()
    {
        var source = new CountingSource();
        var service = new LiveActivityService(
            [source],
            pollInterval: TimeSpan.FromMilliseconds(10));
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(80));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => service.RunAsync(cancellation.Token));

        Assert.True(source.Count >= 2);
    }

    [Fact]
    public async Task PollOnce_keeps_healthy_source_when_another_source_fails()
    {
        var now = DateTimeOffset.UtcNow;
        var healthy = Session("codex", "healthy", now, now);
        var service = new LiveActivityService(
            [
                new ThrowingSource(new InvalidOperationException("broken")),
                new FakeSource("codex", [healthy])
            ]);

        var result = await service.PollOnceAsync();

        Assert.Equal(healthy, Assert.Single(result));
    }

    [Fact]
    public async Task PollOnce_propagates_source_cancellation()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var service = new LiveActivityService(
            [new ThrowingSource(new OperationCanceledException(cancellation.Token))]);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => service.PollOnceAsync(cancellation.Token));
    }

    [Fact]
    public async Task PollOnce_isolates_internal_source_cancellation()
    {
        var now = DateTimeOffset.UtcNow;
        var healthy = Session("claude", "healthy", now, now);
        var service = new LiveActivityService(
            [
                new ThrowingSource(new OperationCanceledException("source timeout")),
                new FakeSource("claude", [healthy])
            ]);

        var result = await service.PollOnceAsync();

        Assert.Equal(healthy, Assert.Single(result));
    }

    [Fact]
    public async Task RunAsync_isolates_each_sessions_changed_subscriber()
    {
        var source = new ChangingSource();
        var service = new LiveActivityService(
            [source],
            pollInterval: TimeSpan.FromMilliseconds(10));
        var observed = 0;
        service.SessionsChanged += (_, _) => throw new InvalidOperationException("UI failed");
        service.SessionsChanged += (_, _) => observed++;
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(80));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => service.RunAsync(cancellation.Token));

        Assert.True(source.Count >= 2);
        Assert.True(observed >= 2);
    }

    [Fact]
    public async Task IdenticalSessionsWithNewAgentListsEmitOnlyOnce()
    {
        var now = DateTimeOffset.UtcNow;
        var source = new RecreatedEquivalentSource(now);
        var service = new LiveActivityService([source]);
        var emitted = 0;
        service.SessionsChanged += (_, _) => emitted++;

        await service.PollOnceAsync();
        await service.PollOnceAsync();

        Assert.Equal(1, emitted);
    }

    private static LiveSession Session(
        string provider,
        string id,
        DateTimeOffset started,
        DateTimeOffset updated) =>
        new(
            provider,
            id,
            "project",
            null,
            "active",
            [],
            null,
            null,
            null,
            LiveTokenSnapshot.Unavailable,
            started,
            updated);

    private sealed class FakeSource(
        string provider,
        IReadOnlyList<LiveSession> sessions) : ILiveSessionSource
    {
        public string Provider => provider;
        public Task<IReadOnlyList<LiveSession>> PollAsync(
            LivePollContext context,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(sessions);
    }

    private sealed class CountingSource : ILiveSessionSource
    {
        public int Count { get; private set; }
        public string Provider => "count";
        public Task<IReadOnlyList<LiveSession>> PollAsync(
            LivePollContext context,
            CancellationToken cancellationToken = default)
        {
            Count++;
            return Task.FromResult<IReadOnlyList<LiveSession>>([]);
        }
    }

    private sealed class ThrowingSource(Exception exception) : ILiveSessionSource
    {
        public string Provider => "throwing";

        public Task<IReadOnlyList<LiveSession>> PollAsync(
            LivePollContext context,
            CancellationToken cancellationToken = default) =>
            Task.FromException<IReadOnlyList<LiveSession>>(exception);
    }

    private sealed class ChangingSource : ILiveSessionSource
    {
        public int Count { get; private set; }
        public string Provider => "changing";

        public Task<IReadOnlyList<LiveSession>> PollAsync(
            LivePollContext context,
            CancellationToken cancellationToken = default)
        {
            Count++;
            return Task.FromResult<IReadOnlyList<LiveSession>>(
                [Session("changing", Count.ToString(), context.Now, context.Now)]);
        }
    }

    private sealed class RecreatedEquivalentSource(DateTimeOffset now) : ILiveSessionSource
    {
        public string Provider => "equivalent";

        public Task<IReadOnlyList<LiveSession>> PollAsync(
            LivePollContext context,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<LiveSession>>(
            [
                new LiveSession(
                    "equivalent",
                    "same",
                    "project",
                    "main",
                    "active",
                    [new LiveAgent("tool", "agent", "work", now)],
                    "task",
                    "result",
                    "model",
                    new LiveTokenSnapshot(
                        1,
                        2,
                        3,
                        4,
                        5,
                        10,
                        LiveTokenScope.SessionCumulative),
                    now,
                    now)
            ]);
    }
}
