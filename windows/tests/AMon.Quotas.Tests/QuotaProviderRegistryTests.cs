using AMon.Quotas;

namespace AMon.Quotas.Tests;

public sealed class QuotaProviderRegistryTests
{
    [Fact]
    public void RegistryListsNineProvidersInMacOSDisplayOrder()
    {
        var providers = QuotaProviderRegistry.Create(
            new FakeFileSystem(),
            new FakeEnvironment(),
            new FixedQuotaClock(DateTimeOffset.UnixEpoch),
            new FakeHttp(),
            new FakeHttp(),
            new FakeCredentialStore(),
            new FakeProcessRunner());

        Assert.Equal(
            ["claude", "codex", "cursor", "copilot", "antigravity", "devin", "grok", "openrouter", "zai"],
            providers.Select(static provider => provider.Id).ToArray());
        Assert.Equal(providers.Count, providers.Select(static provider => provider.DisplayName).Distinct().Count());
    }

    [Fact]
    public async Task NothingIsDetectedOnAnEmptyMachine()
    {
        var providers = QuotaProviderRegistry.Create(
            new FakeFileSystem(),
            new FakeEnvironment(),
            new FixedQuotaClock(DateTimeOffset.UnixEpoch),
            new FakeHttp(),
            new FakeHttp(),
            new FakeCredentialStore(),
            new FakeProcessRunner());

        foreach (var provider in providers)
            Assert.False(await provider.HasLocalCredentialsAsync(CancellationToken.None), provider.Id);
    }
}
