using System.Text.Json;
using AMon.ClaudeIntegration;
using AMon.Core;

namespace AMon.ClaudeIntegration.Tests;

public sealed class ClaudeHookHostRecordingTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"amon-claude-host-tests-{Guid.NewGuid():N}");

    [Fact]
    public void HookRecordsTheDetectedHostAndReplacesItWhenTheChainMoves()
    {
        var host = new HostProcessScanner.Candidate("WindowsTerminal", 4242);
        var processor = new ClaudeHookProcessor(root, hostDetector: () => host);

        processor.Process(Event("SessionStart"));
        var session = Read(processor.GetSessionPath("session/host"));
        Assert.Equal("WindowsTerminal", session.HostApp);
        Assert.Equal(4242, session.HostProcessId);

        host = new HostProcessScanner.Candidate("Code", 99);
        processor.Process(Event("UserPromptSubmit", "\"prompt\": \"resume elsewhere\""));
        session = Read(processor.GetSessionPath("session/host"));
        Assert.Equal("Code", session.HostApp);
        Assert.Equal(99, session.HostProcessId);
    }

    [Fact]
    public void NoDetectableHostLeavesTheFieldsAbsent()
    {
        var processor = new ClaudeHookProcessor(root, hostDetector: () => null);

        processor.Process(Event("SessionStart"));

        var session = Read(processor.GetSessionPath("session/host"));
        Assert.Null(session.HostApp);
        Assert.Null(session.HostProcessId);
    }

    private static string Event(string name, string? extra = null) =>
        $$"""
        {
          "session_id": "session/host",
          "cwd": "C:\\work",
          "hook_event_name": "{{name}}",
          "transcript_path": "C:\\work\\t.jsonl"{{(extra is null ? string.Empty : "," + extra)}}
        }
        """;

    private static ClaudeLiveSession Read(string path) =>
        JsonSerializer.Deserialize<ClaudeLiveSession>(File.ReadAllText(path))!;

    public void Dispose()
    {
        if (Directory.Exists(root))
            Directory.Delete(root, recursive: true);
    }
}
