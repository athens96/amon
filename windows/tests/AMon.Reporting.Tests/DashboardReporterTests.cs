using System.Net;
using Xunit;

namespace AMon.Reporting.Tests;

public sealed class DashboardReporterTests
{
    [Fact]
    public void Retry_delay_is_bounded_exponential_backoff()
    {
        Assert.Equal(TimeSpan.FromSeconds(15), DashboardReporter.RetryDelay(1));
        Assert.Equal(TimeSpan.FromSeconds(30), DashboardReporter.RetryDelay(2));
        Assert.Equal(TimeSpan.FromSeconds(60), DashboardReporter.RetryDelay(3));
        Assert.Equal(TimeSpan.FromMinutes(5), DashboardReporter.RetryDelay(20));
    }

    [Theory]
    [InlineData(HttpStatusCode.RequestTimeout, true)]
    [InlineData(HttpStatusCode.TooManyRequests, true)]
    [InlineData(HttpStatusCode.InternalServerError, true)]
    [InlineData(HttpStatusCode.Unauthorized, false)]
    [InlineData(HttpStatusCode.RequestEntityTooLarge, false)]
    [InlineData(HttpStatusCode.UnprocessableEntity, false)]
    public void Only_transient_statuses_are_retried(HttpStatusCode status, bool expected) =>
        Assert.Equal(expected, DashboardReporter.IsRetryableStatus(status));

    [Fact]
    public void Transport_and_timeout_failures_are_retried()
    {
        Assert.True(DashboardReporter.IsRetryableException(new HttpRequestException()));
        Assert.True(DashboardReporter.IsRetryableException(new TaskCanceledException()));
        Assert.False(DashboardReporter.IsRetryableException(new InvalidOperationException()));
    }
}
