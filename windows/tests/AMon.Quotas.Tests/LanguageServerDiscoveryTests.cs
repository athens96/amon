using AMon.Quotas.Providers.Antigravity;

namespace AMon.Quotas.Tests;

public sealed class LanguageServerDiscoveryTests
{
    private static readonly LanguageServerOptions AntigravityOptions =
        new("language_server", ["antigravity", "antigravity-ide"], "--csrf_token", "--extension_server_port");

    private const string LanguageServerCommand =
        """"
        "C:\Users\t\AppData\Local\Programs\Antigravity\resources\app\bin\language_server_windows_x64.exe" --csrf_token abc --extension_server_port 4321 --app_data_dir antigravity
        """";

    [Fact]
    public void RankedCandidatesMatchesQuotedWindowsLanguageServer()
    {
        var candidates = LanguageServerDiscovery.RankedCandidates($"1234 {LanguageServerCommand}\n", AntigravityOptions);

        var candidate = Assert.Single(candidates);
        Assert.Equal(1234, candidate.Pid);
        Assert.Equal("abc", LanguageServerDiscovery.ExtractFlag(candidate.Command, "--csrf_token"));
        Assert.Equal("4321", LanguageServerDiscovery.ExtractFlag(candidate.Command, "--extension_server_port"));
    }

    [Fact]
    public void RankedCandidatesRejectsANeighbouringMarker()
    {
        var command = LanguageServerCommand.Replace("--app_data_dir antigravity", "--app_data_dir antigravity-next", StringComparison.Ordinal);

        Assert.Empty(LanguageServerDiscovery.RankedCandidates($"1234 {command}\n", AntigravityOptions));
    }

    [Fact]
    public void RankedCandidatesPutsAnExactMarkerBeforeAPathMarker()
    {
        var pathMatch = """"
            "C:\Tools\antigravity\bin\language_server.exe" --csrf_token zzz --extension_server_port 1111
            """";
        var processList = $"999 {pathMatch}\n1234 {LanguageServerCommand}\n";

        var candidates = LanguageServerDiscovery.RankedCandidates(processList, AntigravityOptions);

        Assert.Equal(new[] { 1234, 999 }, candidates.Select(candidate => candidate.Pid).ToArray());
    }

    [Fact]
    public void RankedCandidatesMatchesAgyWithoutMarkers()
    {
        var options = new LanguageServerOptions("agy", [], string.Empty, null);
        var processList = "77 C:\\Users\\t\\.agy\\bin\\agy.exe serve\n88 C:\\Windows\\System32\\notepad.exe\n";

        var candidates = LanguageServerDiscovery.RankedCandidates(processList, options);

        Assert.Equal(77, Assert.Single(candidates).Pid);
    }

    [Theory]
    [InlineData(@"C:\Program Files\Antigravity\language_server_windows_x64.exe --port 1", "language_server", true)]
    [InlineData(@"C:\Users\t\.agy\bin\agy.exe serve", "agy", true)]
    [InlineData(@"C:\Windows\System32\notepad.exe", "agy", false)]
    [InlineData("/opt/antigravity/language_server --port 1", "language_server", true)]
    public void CommandMatchesProcessHandlesWindowsAndPosixShapes(string command, string processName, bool expected) =>
        Assert.Equal(expected, LanguageServerDiscovery.CommandMatchesProcess(command, processName));

    [Fact]
    public void Argv0HonoursAQuotedExecutablePathWithSpaces()
    {
        Assert.Equal(
            @"C:\Program Files\Antigravity\language_server.exe",
            LanguageServerDiscovery.Argv0("\"C:\\Program Files\\Antigravity\\language_server.exe\" --csrf_token a"));
        Assert.Equal(@"C:\Antigravity\agy.exe", LanguageServerDiscovery.Argv0(@"  C:\Antigravity\agy.exe serve"));
    }

    [Fact]
    public void ExtractFlagReadsBothSpacedAndEqualsForms()
    {
        Assert.Equal("abc", LanguageServerDiscovery.ExtractFlag("app.exe --csrf_token abc", "--csrf_token"));
        Assert.Equal("abc", LanguageServerDiscovery.ExtractFlag("app.exe --csrf_token=abc", "--csrf_token"));
        Assert.Null(LanguageServerDiscovery.ExtractFlag("app.exe --csrf_token", "--csrf_token"));
        Assert.Null(LanguageServerDiscovery.ExtractFlag("app.exe --other abc", "--csrf_token"));
    }

    [Fact]
    public void MarkerRankPrefersAnExactFlagValueOverAPathSubstring()
    {
        Assert.Equal(0, LanguageServerDiscovery.MarkerRank(LanguageServerCommand, ["antigravity"]));
        Assert.Equal(1, LanguageServerDiscovery.MarkerRank(@"C:\Tools\antigravity\bin\language_server.exe", ["antigravity"]));
        Assert.Null(LanguageServerDiscovery.MarkerRank(@"C:\Tools\other\bin\language_server.exe", ["antigravity"]));
        Assert.Equal(0, LanguageServerDiscovery.MarkerRank(@"C:\Tools\other\bin\agy.exe", []));
    }

    [Fact]
    public void ParseListeningPortsKeepsOnlyListeningRowsOwnedByThePid()
    {
        const string netstat = """
            Active Connections

              Proto  Local Address          Foreign Address        State           PID
              TCP    127.0.0.1:52170        0.0.0.0:0              LISTENING       1234
              TCP    127.0.0.1:52168        0.0.0.0:0              LISTENING       1234
              TCP    127.0.0.1:52168        127.0.0.1:52180        ESTABLISHED     1234
              TCP    127.0.0.1:9999         0.0.0.0:0              LISTENING       999
              TCP    [::]:52171             [::]:0                 LISTENING       1234
            """;

        Assert.Equal(new[] { 52168, 52170, 52171 }, LanguageServerDiscovery.ParseListeningPorts(netstat, 1234).ToArray());
        Assert.Equal(new[] { 9999 }, LanguageServerDiscovery.ParseListeningPorts(netstat, 999).ToArray());
        Assert.Empty(LanguageServerDiscovery.ParseListeningPorts(netstat, 5));
    }

    [Fact]
    public async Task DiscoverReturnsNullWhenTheProcessListIsUnavailable()
    {
        var discovery = new LanguageServerDiscovery(new FakeProcessRunner());

        Assert.Null(await discovery.DiscoverAsync(AntigravityOptions, CancellationToken.None));
    }

    [Fact]
    public async Task DiscoverReadsCsrfPortsAndTheExtensionPort()
    {
        var runner = new FakeProcessRunner();
        runner.Results["powershell.exe"] = new ProcessRunResult(0, $"1234 {LanguageServerCommand}\n");
        runner.Results["netstat.exe"] = new ProcessRunResult(
            0,
            "  TCP    127.0.0.1:52168        0.0.0.0:0              LISTENING       1234\n");

        var result = await new LanguageServerDiscovery(runner).DiscoverAsync(AntigravityOptions, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal(1234, result.Pid);
        Assert.Equal("abc", result.Csrf);
        Assert.Equal(new[] { 52168 }, result.Ports.ToArray());
        Assert.Equal(4321, result.ExtensionPort);
    }
}
