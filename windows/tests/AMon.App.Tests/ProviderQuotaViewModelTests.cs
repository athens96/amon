using AMon.App.ViewModels;

namespace AMon.App.Tests;

public sealed class ProviderQuotaViewModelTests
{
    [Fact]
    public void PercentMetricShowsUsedAndRemainingAmounts()
    {
        var metric = ProviderQuotaMetricViewModel.Percent(
            "세션",
            37.5,
            DateTimeOffset.UtcNow.AddHours(2));

        Assert.Equal(37.5, metric.UsedPercent);
        Assert.Equal(62.5, metric.RemainingPercent);
        Assert.Equal("37.5% 사용", metric.UsedText);
        Assert.Equal("62.5% 남음", metric.RemainingText);
        Assert.NotNull(metric.ResetText);
    }

    [Fact]
    public void DashboardReplacesQuotaSnapshotsAtomically()
    {
        var dashboard = new DashboardViewModel();
        var quota = ProviderQuotaViewModel.Success(
            "Codex",
            "Plus",
            [ProviderQuotaMetricViewModel.Percent("주간", 25, null)]);

        dashboard.ApplyProviderQuotas([quota]);

        var actual = Assert.Single(dashboard.ProviderQuotas);
        Assert.Equal("Codex", actual.Provider);
        Assert.Equal("Plus", actual.Plan);
        Assert.Equal("75% 남음", Assert.Single(actual.Metrics).RemainingText);
    }
}
