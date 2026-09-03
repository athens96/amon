using AMon.Core;
using Xunit;

namespace AMon.Core.Tests;

public sealed class CursorSessionTokenEstimatorTests
{
    private static readonly DateTimeOffset T0 = new(2026, 9, 3, 10, 0, 0, TimeSpan.Zero);

    private static CursorUsageEvent Event(DateTimeOffset at, string model, long input, long output) =>
        new(at, model, input, output, 0, 0, null);

    [Fact]
    public void EventsGoToTheSessionWithTheNearestBubble()
    {
        var sessions = new[]
        {
            new CursorSessionTokenEstimator.SessionBubbles("a", [T0, T0.AddMinutes(5)]),
            new CursorSessionTokenEstimator.SessionBubbles("b", [T0.AddMinutes(30)]),
            new CursorSessionTokenEstimator.SessionBubbles("empty", []),
        };
        var events = new[]
        {
            Event(T0.AddMinutes(1), "claude-4", 100, 10),
            Event(T0.AddMinutes(6), "gpt-5", 50, 5),
            Event(T0.AddMinutes(29), "claude-4", 30, 3),
            Event(T0.AddHours(3), "claude-4", 999, 99), // farther than MaxGap from every bubble
        };

        var estimates = CursorSessionTokenEstimator.Attribute(events, sessions);

        Assert.Equal(2, estimates.Count);
        Assert.Equal(150, estimates["a"].Usage.InputTokens);
        Assert.Equal(15, estimates["a"].Usage.OutputTokens);
        Assert.Equal("claude-4", estimates["a"].TopModel);
        Assert.Equal(110, estimates["a"].Models["claude-4"]);
        Assert.Equal(33, estimates["b"].Usage.TotalTokens);
        Assert.False(estimates.ContainsKey("empty"));
    }

    [Fact]
    public void NoBubblesOrNoEventsMeansNoEstimate()
    {
        Assert.Empty(CursorSessionTokenEstimator.Attribute([], [new CursorSessionTokenEstimator.SessionBubbles("a", [T0])]));
        Assert.Empty(CursorSessionTokenEstimator.Attribute([Event(T0, "m", 1, 1)], []));
    }

    [Fact]
    public void CacheRoundTripsThroughDisk()
    {
        var path = Path.Combine(Path.GetTempPath(), $"amon-cursor-events-{Guid.NewGuid():N}", "cursor-events.json");
        var events = new[] { new CursorUsageEvent(T0, "claude-4", 1, 2, 3, 4, 10) };

        CursorUsageEventCache.Store(path, T0, events);
        var loaded = CursorUsageEventCache.Load(path);

        Assert.NotNull(loaded);
        Assert.Equal(T0, loaded!.FetchedAt);
        Assert.Equal(events, loaded.Events);
        Assert.Equal(10, loaded.Events[0].Usage.TotalTokens);
        Assert.Null(CursorUsageEventCache.Load(path + ".missing"));
        Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
    }
}
