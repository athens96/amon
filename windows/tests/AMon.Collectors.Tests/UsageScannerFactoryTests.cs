using AMon.Collectors;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class UsageScannerFactoryTests
{
    [Fact]
    public void Create_returns_all_seven_tools_in_stable_order()
    {
        var scanners = UsageScannerFactory.Create();

        Assert.Equal(
            ["claudeCode", "codex", "openCode", "cursor", "gemini", "qwen", "copilot"],
            scanners.Select(static scanner => scanner.Tool));
    }
}
