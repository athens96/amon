using System.Text.Json;
using AMon.Quotas;
using AMon.Quotas.Providers.Antigravity;
using AMon.Quotas.Providers.Devin;

namespace AMon.Quotas.Tests;

/// Regressions found in review: mappers must degrade, never throw, on out-of-range or malformed
/// provider values.
public sealed class ReviewRegressionTests
{
    [Theory]
    [InlineData(1_756_818_000d)]           // seconds, in range
    [InlineData(1_756_818_000_000d)]       // milliseconds passed as seconds → year 57,000 → null
    [InlineData(-1e18)]
    [InlineData(double.PositiveInfinity)]
    [InlineData(double.NaN)]
    public void EpochConversionNeverThrows(double seconds)
    {
        var fromSeconds = QuotaTime.FromEpochSeconds(seconds);
        var fromMilliseconds = QuotaTime.FromEpochMilliseconds(seconds * 1000);
        if (seconds == 1_756_818_000d)
        {
            Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_756_818_000), fromSeconds);
            Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_756_818_000), fromMilliseconds);
        }
        else
        {
            Assert.Null(fromSeconds);
            Assert.Null(fromMilliseconds);
        }
    }

    [Theory]
    [InlineData("https://server.codeium.com/", "https://server.codeium.com")]
    [InlineData("https://server.codeium.com", "https://server.codeium.com")]
    [InlineData("http://server.codeium.com", null)]
    [InlineData("https:// x", null)]
    [InlineData("https://", null)]
    [InlineData("", null)]
    public void DevinServerOverrideMustBeAValidHttpsUrl(string value, string? expected) =>
        Assert.Equal(expected, DevinAuthStore.CleanApiServerUrl(value));

    [Fact]
    public void DevinHideDailyQuotaIgnoresNumericTruthiness()
    {
        using var document = JsonDocument.Parse(
            """{"planStatus":{"planInfo":{"planName":"Core","hideDailyQuota":1},"dailyQuotaRemainingPercent":80,"weeklyQuotaRemainingPercent":50}}""");

        var mapped = DevinUsageMapper.MapUserStatus(document.RootElement);

        Assert.NotNull(mapped);
        Assert.Contains(mapped!.Lines, static line => line.Label == "Daily quota");
    }

    [Fact]
    public async Task InvalidUrlIsATransportFailureNotAnException()
    {
        using var http = new HttpClientQuotaHttp();

        await Assert.ThrowsAsync<System.Net.Http.HttpRequestException>(() =>
            http.SendAsync(QuotaHttpRequest.Get("https:// x/path"), CancellationToken.None));
    }

    [Fact]
    public void ProcessListScriptBypassesPowerShellLineWrapping() =>
        Assert.Contains("[Console]::Out.WriteLine", LanguageServerDiscovery.ProcessListScript);
}
