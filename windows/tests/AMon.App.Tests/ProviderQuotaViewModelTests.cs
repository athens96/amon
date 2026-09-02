using AMon.App.ViewModels;
using AMon.Quotas;

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

        Assert.True(metric.HasProgress);
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

    [Fact]
    public void DollarsProgressFormatsUsedAgainstLimit()
    {
        var metric = ProviderQuotaMetricViewModel.FromLine(
            new QuotaProgressLine("Credits", 4.08, 20, QuotaMetricKind.Dollars));

        Assert.True(metric.HasProgress);
        Assert.Equal("dollars", metric.Kind);
        Assert.Equal(20.4, metric.UsedPercent, 3);
        Assert.Equal("$4.08 / $20.00", metric.UsedText);
        Assert.Equal("$15.92 남음", metric.RemainingText);
    }

    [Fact]
    public void CountProgressCarriesSuffix()
    {
        var metric = ProviderQuotaMetricViewModel.FromLine(
            new QuotaProgressLine("Web Searches", 12, 100, QuotaMetricKind.Count, CountSuffix: "searches"));

        Assert.Equal("12 / 100 searches", metric.UsedText);
        Assert.Equal("88 searches 남음", metric.RemainingText);
        Assert.Equal("normal", metric.Severity);
    }

    [Fact]
    public void UnboundedRowsRenderWithoutBarAndNeverAlert()
    {
        var values = ProviderQuotaMetricViewModel.FromLine(
            new QuotaValuesLine("Balance", [new QuotaMetricValue(1234.5, QuotaMetricKind.Dollars)]));
        var badge = ProviderQuotaMetricViewModel.FromLine(new QuotaBadgeLine("Pay as you go", "Disabled"));

        Assert.False(values.HasProgress);
        Assert.Equal("$1.2K", values.RemainingText);
        Assert.Equal(100, values.RemainingPercent);
        Assert.Equal("normal", values.Severity);
        Assert.False(badge.HasProgress);
        Assert.Equal("Disabled", badge.RemainingText);
    }

    [Fact]
    public void SnapshotErrorBecomesStatusWithoutMetrics()
    {
        var snapshot = new QuotaSnapshot("grok", "Grok", null, [], DateTimeOffset.UtcNow, "Grok 로그인이 필요합니다.");

        var card = ProviderQuotaViewModel.FromSnapshot(snapshot);

        Assert.Equal("grok", card.ProviderId);
        Assert.Equal("Grok", card.Provider);
        Assert.Equal("Grok 로그인이 필요합니다.", card.Status);
        Assert.Empty(card.Metrics);
        Assert.False(card.HasAlert);
    }

    [Fact]
    public void SnapshotWithCriticalMeterRaisesCardSeverity()
    {
        var snapshot = new QuotaSnapshot(
            "copilot",
            "GitHub Copilot",
            "Copilot Pro",
            [
                new QuotaProgressLine("Credits", 95, 100, QuotaMetricKind.Percent),
                new QuotaValuesLine("Extra Usage", [new QuotaMetricValue(3, QuotaMetricKind.Count)]),
            ],
            DateTimeOffset.UtcNow);

        var card = ProviderQuotaViewModel.FromSnapshot(snapshot);

        Assert.Equal("Copilot Pro", card.Plan);
        Assert.Equal("방금 갱신", card.Status);
        Assert.Equal("critical", card.Severity);
        Assert.Single(card.ProgressMetrics);
        Assert.Equal("3", card.Metrics[1].RemainingText);
    }

    [Fact]
    public void CompactFormattingMatchesMacOS()
    {
        Assert.Equal("1.2M", QuotaMetricFormat.Compact(1_250_000));
        Assert.Equal("12.4K", QuotaMetricFormat.Compact(12_400));
        Assert.Equal("$4.08", QuotaMetricFormat.Dollars(4.08));
        Assert.Equal("$1.2K", QuotaMetricFormat.Dollars(1234.5));
        Assert.Equal("$4.08 · 1.2M tokens", QuotaMetricFormat.Values(
        [
            new QuotaMetricValue(4.08, QuotaMetricKind.Dollars),
            new QuotaMetricValue(1_250_000, QuotaMetricKind.Count, "tokens"),
        ]));
    }
}
