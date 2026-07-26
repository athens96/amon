using AMon.Core;
using Xunit;

namespace AMon.Core.Tests;

public sealed class TokenUsageTests
{
    [Fact]
    public void Add_combines_every_token_bucket()
    {
        var result = new TokenUsage(1, 2, 3, 4, 5).Add(new TokenUsage(5, 4, 3, 2, 1));

        Assert.Equal(new TokenUsage(6, 6, 6, 6, 6), result);
        Assert.Equal(24, result.TotalTokens);
    }

    [Fact]
    public void Reported_total_is_preserved_when_provider_total_differs_from_components()
    {
        var result = new TokenUsage(10, 2, ReportedTotalTokens: 20)
            .Add(new TokenUsage(3, 1));

        Assert.Equal(24, result.TotalTokens);
        Assert.Equal(16, result.InputTokens + result.OutputTokens);
    }
}
