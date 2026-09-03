using AMon.Core;
using Xunit;

namespace AMon.Core.Tests;

public sealed class HostProcessScannerTests
{
    private static ProcessTree Tree(params ProcessEntry[] entries) =>
        new(entries.ToDictionary(static entry => entry.ProcessId));

    [Fact]
    public void HostIsTheNearestWindowedAncestorAboveShellsAndRuntimes()
    {
        // WindowsTerminal(10) → pwsh(20) → claude(30) → node(40) → hook(50)
        var tree = Tree(
            new ProcessEntry(10, 4, "WindowsTerminal"),
            new ProcessEntry(20, 10, "pwsh"),
            new ProcessEntry(30, 20, "claude"),
            new ProcessEntry(40, 30, "node"),
            new ProcessEntry(50, 40, "AMon.ClaudeHook"));

        var host = HostProcessScanner.HostOf(tree, 50, pid => pid is 10 or 20);

        Assert.NotNull(host);
        Assert.Equal("WindowsTerminal", host!.HostApp);
        Assert.Equal(10, host.HostProcessId);
    }

    [Fact]
    public void ExplorerAboveAConsoleShellIsNotAHost()
    {
        // explorer(5) → cmd(20) → claude(30): the console belongs to conhost (a child), so the walk
        // would otherwise reach the desktop window owned by explorer.
        var tree = Tree(
            new ProcessEntry(5, 4, "explorer"),
            new ProcessEntry(20, 5, "cmd"),
            new ProcessEntry(30, 20, "claude"));

        Assert.Null(HostProcessScanner.HostOf(tree, 30, _ => true));
    }

    [Fact]
    public void NoWindowedAncestorMeansNoHost()
    {
        var tree = Tree(
            new ProcessEntry(10, 4, "svchost"),
            new ProcessEntry(20, 10, "cmd"),
            new ProcessEntry(30, 20, "claude"));

        Assert.Null(HostProcessScanner.HostOf(tree, 30, _ => false));
    }

    [Fact]
    public void AncestorWalkStopsOnRecycledPidCycles()
    {
        var tree = Tree(
            new ProcessEntry(10, 20, "a"),
            new ProcessEntry(20, 10, "b"));

        Assert.Equal(["b"], tree.Ancestors(10).Select(static entry => entry.Name).ToArray());
    }

    [Fact]
    public void SelectOnlyGuessesWhenEveryCandidateSharesOneHost()
    {
        var code = new HostProcessScanner.Candidate("Code", 1);
        var terminal = new HostProcessScanner.Candidate("WindowsTerminal", 2);

        Assert.Null(HostProcessScanner.Select([code, terminal]));
        Assert.Same(code, HostProcessScanner.Select([code, code with { HostProcessId = 3 }]));
        Assert.Null(HostProcessScanner.Select([]));
    }

    [Fact]
    public void CandidatesListEveryHostOfNamedProcesses()
    {
        var tree = Tree(
            new ProcessEntry(10, 4, "Code"),
            new ProcessEntry(11, 10, "claude"),
            new ProcessEntry(20, 4, "WindowsTerminal"),
            new ProcessEntry(21, 20, "pwsh"),
            new ProcessEntry(22, 21, "claude"),
            new ProcessEntry(30, 4, "codex"));

        var candidates = HostProcessScanner.Candidates(tree, "claude", pid => pid is 10 or 20);

        Assert.Equal(["Code", "WindowsTerminal"], candidates.Select(static candidate => candidate.HostApp).OrderBy(static name => name).ToArray());
    }
}
