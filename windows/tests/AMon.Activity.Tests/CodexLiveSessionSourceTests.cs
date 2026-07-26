using Xunit;

namespace AMon.Activity.Tests;

public sealed class CodexLiveSessionSourceTests
{
    [Fact]
    public async Task Lifecycle_overrides_mtime_and_parses_safe_latest_state()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("codex-live");
        var file = Path.Combine(directory, "rollout-live.jsonl");
        var lines = new[]
        {
            TestSupport.Json(new { timestamp = now, type = "session_meta", payload = new { id = "s1", cwd = @"C:\work\project" } }),
            TestSupport.Json(new { timestamp = now, type = "response_item", payload = new { type = "message", role = "user", content = new[] { new { type = "input_text", text = "# AGENTS.md instructions\nsecret" } } } }),
            TestSupport.Json(new { timestamp = now, type = "event_msg", payload = new { type = "user_message", message = "실제 작업\n비공개 둘째 줄" } }),
            TestSupport.Json(new { timestamp = now, type = "turn_context", payload = new { cwd = @"C:\work\project", model = "gpt-5" } }),
            TestSupport.Json(new { timestamp = now, type = "response_item", payload = new { type = "message", role = "assistant", content = new[] { new { type = "output_text", text = "완료 결과\n비공개 둘째 줄" } } } }),
            TestSupport.Json(new { timestamp = now, type = "event_msg", payload = new { type = "agent_message", message = "{\"kind\":\"internal\"}" } }),
            TestSupport.Json(new { timestamp = now, type = "event_msg", payload = new { type = "token_count", info = new { total_token_usage = new { input_tokens = 100, cached_input_tokens = 40, output_tokens = 20, reasoning_output_tokens = 5, total_tokens = 120 } } } }),
            TestSupport.Json(new { timestamp = now, type = "event_msg", payload = new { type = "task_started" } }),
            TestSupport.Json(new { timestamp = now, type = "event_msg", payload = new { type = "task_complete" } })
        };
        await File.WriteAllTextAsync(file, string.Join('\n', lines) + "\n");
        File.SetLastWriteTimeUtc(file, now.UtcDateTime);

        var session = Assert.Single(await new CodexLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now))));

        Assert.Equal("idle", session.Status);
        Assert.Equal("실제 작업", session.CurrentTask);
        Assert.Equal("완료 결과", session.LastResult);
        Assert.Equal("gpt-5", session.Model);
        Assert.Equal(60, session.Tokens.InputTokens);
        Assert.Equal(40, session.Tokens.CacheReadTokens);
        Assert.Equal(120, session.Tokens.TotalTokens);
        Assert.Equal(LiveTokenScope.SessionCumulative, session.Tokens.Scope);
    }

    [Theory]
    [InlineData("exec_approval_request")]
    [InlineData("apply_patch_approval_request")]
    [InlineData("request_user_input")]
    public async Task Pending_attention_events_surface_needs_input(string eventType)
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("codex-attention");
        var file = Path.Combine(directory, "rollout-attention.jsonl");
        await File.WriteAllTextAsync(
            file,
            string.Join(
                '\n',
                [
                    TestSupport.Json(new
                    {
                        timestamp = now,
                        type = "session_meta",
                        payload = new { id = "attention", cwd = directory }
                    }),
                    TestSupport.Json(new
                    {
                        timestamp = now.AddSeconds(1),
                        type = "event_msg",
                        payload = new { type = "turn_started" }
                    }),
                    TestSupport.Json(new
                    {
                        timestamp = now.AddSeconds(2),
                        type = "event_msg",
                        payload = new { type = eventType }
                    })
                ]) + "\n");
        File.SetLastWriteTimeUtc(file, now.AddSeconds(2).UtcDateTime);

        var session = Assert.Single(await new CodexLiveSessionSource(directory)
            .PollAsync(new LivePollContext(
                new MutableTimeProvider(now.AddSeconds(2)))));

        Assert.Equal("needs_input", session.Status);
    }

    [Fact]
    public async Task Attention_response_resumes_and_failure_surfaces_blocked()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("codex-attention-transitions");
        var file = Path.Combine(directory, "rollout-transitions.jsonl");
        var initial = new[]
        {
            TestSupport.Json(new
            {
                timestamp = now,
                type = "session_meta",
                payload = new { id = "transitions", cwd = directory }
            }),
            TestSupport.Json(new
            {
                timestamp = now.AddSeconds(1),
                type = "event_msg",
                payload = new { type = "request_user_input" }
            }),
            TestSupport.Json(new
            {
                timestamp = now.AddSeconds(2),
                type = "response_item",
                payload = new
                {
                    type = "function_call_output",
                    call_id = "request-1",
                    output = "approved"
                }
            }),
            TestSupport.Json(new
            {
                timestamp = now.AddSeconds(3),
                type = "event_msg",
                payload = new { type = "turn_started" }
            })
        };
        await File.WriteAllTextAsync(file, string.Join('\n', initial) + "\n");
        File.SetLastWriteTimeUtc(file, now.AddSeconds(3).UtcDateTime);

        var source = new CodexLiveSessionSource(directory);
        var resumed = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddSeconds(3)))));
        Assert.Equal("active", resumed.Status);

        await File.AppendAllTextAsync(
            file,
            TestSupport.Json(new
            {
                timestamp = now.AddSeconds(4),
                type = "event_msg",
                payload = new { type = "error", message = "tool failed" }
            }) + "\n");
        File.SetLastWriteTimeUtc(file, now.AddSeconds(4).UtcDateTime);

        var blocked = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddSeconds(4)))));
        Assert.Equal("blocked", blocked.Status);
    }

    [Fact]
    public async Task Pending_request_user_input_function_call_surfaces_needs_input()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("codex-function-attention");
        var file = Path.Combine(directory, "rollout-function-attention.jsonl");
        await File.WriteAllTextAsync(
            file,
            string.Join(
                '\n',
                [
                    TestSupport.Json(new
                    {
                        timestamp = now,
                        type = "session_meta",
                        payload = new { id = "function-attention", cwd = directory }
                    }),
                    TestSupport.Json(new
                    {
                        timestamp = now.AddSeconds(1),
                        type = "response_item",
                        payload = new
                        {
                            type = "function_call",
                            name = "request_user_input",
                            call_id = "request-1"
                        }
                    })
                ]) + "\n");
        File.SetLastWriteTimeUtc(file, now.AddSeconds(1).UtcDateTime);

        var session = Assert.Single(await new CodexLiveSessionSource(directory)
            .PollAsync(new LivePollContext(
                new MutableTimeProvider(now.AddSeconds(1)))));

        Assert.Equal("needs_input", session.Status);
    }

    [Fact]
    public async Task Legacy_status_uses_90_seconds_and_scan_is_limited_to_20()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("codex-limit");
        for (var index = 0; index < 21; index++)
        {
            var file = Path.Combine(directory, $"rollout-{index:00}.jsonl");
            await File.WriteAllTextAsync(file, TestSupport.Json(new
            {
                timestamp = now.AddSeconds(-index),
                type = "session_meta",
                payload = new { id = $"s-{index}", cwd = directory }
            }) + "\n");
            File.SetLastWriteTimeUtc(file, now.AddSeconds(-index).UtcDateTime);
        }

        var source = new CodexLiveSessionSource(directory);
        var active = await source.PollAsync(new LivePollContext(new MutableTimeProvider(now)));
        var idle = await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddSeconds(91))));

        Assert.Equal(20, active.Count);
        Assert.All(active, session => Assert.Equal("active", session.Status));
        Assert.All(idle, session => Assert.Equal("idle", session.Status));
        Assert.Equal(20, source.ParsedFileCount);
        Assert.Equal(20, source.CachedFileCount);
    }

    [Fact]
    public async Task Legacy_cached_status_transitions_from_89_to_91_seconds_without_reparse()
    {
        var now = DateTimeOffset.UtcNow;
        var modifiedAt = now.AddSeconds(-89);
        var directory = TestSupport.TempDirectory("codex-boundary");
        var file = Path.Combine(directory, "rollout-boundary.jsonl");
        await File.WriteAllTextAsync(file, TestSupport.Json(new
        {
            timestamp = modifiedAt,
            type = "session_meta",
            payload = new { id = "boundary", cwd = directory }
        }) + "\n");
        File.SetLastWriteTimeUtc(file, modifiedAt.UtcDateTime);

        var source = new CodexLiveSessionSource(directory);
        var at89Seconds = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now))));
        var at91Seconds = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddSeconds(2)))));

        Assert.Equal("active", at89Seconds.Status);
        Assert.Equal("idle", at91Seconds.Status);
        Assert.Equal(1, source.ParsedFileCount);
    }

    [Fact]
    public async Task Cache_reparses_mutation_and_sweeps_deleted_files()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("codex-cache");
        var file = Path.Combine(directory, "rollout-cache.jsonl");
        await File.WriteAllTextAsync(file, TestSupport.Json(new
        {
            timestamp = now,
            type = "session_meta",
            payload = new { id = "cached", cwd = directory }
        }) + "\n");
        File.SetLastWriteTimeUtc(file, now.UtcDateTime);

        var source = new CodexLiveSessionSource(directory);
        var initial = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now))));
        var cacheHit = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddSeconds(1)))));

        Assert.Equal(initial, cacheHit);
        Assert.Equal(1, source.ParsedFileCount);
        Assert.Equal(1, source.CachedFileCount);

        await File.AppendAllTextAsync(file, TestSupport.Json(new
        {
            timestamp = now.AddSeconds(2),
            type = "event_msg",
            payload = new { type = "user_message", message = "변경된 작업" }
        }) + "\n");
        File.SetLastWriteTimeUtc(file, now.AddSeconds(2).UtcDateTime);

        var mutated = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddSeconds(2)))));
        Assert.Equal("변경된 작업", mutated.CurrentTask);
        Assert.Equal(2, source.ParsedFileCount);
        Assert.Equal(1, source.CachedFileCount);

        File.Delete(file);
        Assert.Empty(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddSeconds(3)))));
        Assert.Equal(2, source.ParsedFileCount);
        Assert.Equal(0, source.CachedFileCount);
    }

    [Fact]
    public async Task Configured_path_trims_and_expands_environment_variables()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("codex-expanded-path");
        var file = Path.Combine(directory, "rollout-expanded.jsonl");
        await File.WriteAllTextAsync(
            file,
            TestSupport.Json(new
            {
                timestamp = now,
                type = "session_meta",
                payload = new { id = "expanded", cwd = directory }
            }) + "\n");
        File.SetLastWriteTimeUtc(file, now.UtcDateTime);

        var variable = $"AMON_CODEX_PATH_{Guid.NewGuid():N}";
        var previous = Environment.GetEnvironmentVariable(variable);
        Environment.SetEnvironmentVariable(variable, directory);
        try
        {
            var configured = $"  %{variable}%  ";
            var session = Assert.Single(await new CodexLiveSessionSource(configured)
                .PollAsync(new LivePollContext(new MutableTimeProvider(now))));

            Assert.Equal("expanded", session.SessionId);
        }
        finally
        {
            Environment.SetEnvironmentVariable(variable, previous);
        }
    }

    [Fact]
    public async Task Valid_wrong_shape_lines_do_not_drop_the_file_or_provider()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("codex-hostile");
        var validFile = Path.Combine(directory, "rollout-valid.jsonl");
        await File.WriteAllTextAsync(
            validFile,
            string.Join('\n',
            [
                "[]",
                "42",
                "\"scalar\"",
                TestSupport.Json(new
                {
                    timestamp = now,
                    type = "session_meta",
                    payload = Array.Empty<object>()
                }),
                TestSupport.Json(new
                {
                    timestamp = now,
                    type = "response_item",
                    payload = new
                    {
                        type = "message",
                        role = "user",
                        content = new object[] { 1, "wrong" }
                    }
                }),
                TestSupport.Json(new
                {
                    timestamp = now,
                    type = "session_meta",
                    payload = new { id = "valid", cwd = directory }
                })
            ]) + "\n");
        File.SetLastWriteTimeUtc(validFile, now.UtcDateTime);

        var badFile = Path.Combine(directory, "rollout-bad.jsonl");
        await File.WriteAllTextAsync(badFile, "null\n{}\n");
        File.SetLastWriteTimeUtc(badFile, now.UtcDateTime);

        var sessions = await new CodexLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now)));

        Assert.Equal("valid", Assert.Single(sessions).SessionId);
    }
}
