using AMon.Reporting;
using Xunit;

namespace AMon.Reporting.Tests;

public sealed class ServerEndpointTests
{
    [Theory]
    [InlineData("127.0.0.1:3000", "http://127.0.0.1:3000/")]
    [InlineData("localhost:3000", "http://localhost:3000/")]
    [InlineData("https://monitor.example.com/base", "https://monitor.example.com/base")]
    public void NormalizesSupportedAddresses(string input, string expected)
    {
        Assert.True(ServerEndpoint.TryNormalize(input, out var server));
        Assert.Equal(expected, server!.AbsoluteUri);
    }

    [Theory]
    [InlineData("monitor.example.com")]
    [InlineData("ftp://monitor.example.com")]
    [InlineData("")]
    public void RejectsAmbiguousOrUnsupportedAddresses(string input)
    {
        Assert.False(ServerEndpoint.TryNormalize(input, out var server));
        Assert.Null(server);
    }
}
