using AMon.Collectors;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class IncrementalScanCacheTests
{
    [Fact]
    public async Task File_cache_reuses_unchanged_reparses_changed_and_removes_deleted()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "session.jsonl");
        await File.WriteAllTextAsync(path, "first");
        var cache = new IncrementalFileCache<string>();

        var first = await cache.ResolveAsync(
            [path],
            static async (file, cancellationToken) =>
                await File.ReadAllTextAsync(file, cancellationToken),
            default);
        var unchanged = await cache.ResolveAsync(
            [path],
            static async (file, cancellationToken) =>
                await File.ReadAllTextAsync(file, cancellationToken),
            default);

        Assert.Equal("first", Assert.Single(first).Value);
        Assert.Equal("first", Assert.Single(unchanged).Value);
        Assert.Equal(1, cache.ParseCount);

        await File.WriteAllTextAsync(path, "changed-and-longer");
        var changed = await cache.ResolveAsync(
            [path],
            static async (file, cancellationToken) =>
                await File.ReadAllTextAsync(file, cancellationToken),
            default);

        Assert.Equal("changed-and-longer", Assert.Single(changed).Value);
        Assert.Equal(2, cache.ParseCount);

        File.Delete(path);
        var deleted = await cache.ResolveAsync(
            Array.Empty<string>(),
            static (_, _) => ValueTask.FromResult(string.Empty),
            default);

        Assert.Empty(deleted);
        Assert.Equal(0, cache.EntryCount);
    }

    [Fact]
    public async Task Changed_file_parse_failure_keeps_last_good_and_retries()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "session.jsonl");
        await File.WriteAllTextAsync(path, "good");
        var cache = new IncrementalFileCache<string>();
        await cache.ResolveAsync(
            [path],
            static async (file, cancellationToken) =>
                await File.ReadAllTextAsync(file, cancellationToken),
            default);

        await File.WriteAllTextAsync(path, "temporarily-unreadable");
        var stale = await cache.ResolveAsync(
            [path],
            static (_, _) => ValueTask.FromException<string>(
                new IOException("writer still owns the replacement")),
            default);

        Assert.Equal("good", Assert.Single(stale).Value);
        Assert.Equal(1, cache.ParseCount);

        var recovered = await cache.ResolveAsync(
            [path],
            static async (file, cancellationToken) =>
                await File.ReadAllTextAsync(file, cancellationToken),
            default);

        Assert.Equal("temporarily-unreadable", Assert.Single(recovered).Value);
        Assert.Equal(2, cache.ParseCount);
    }

    [Fact]
    public async Task Sqlite_source_fingerprint_invalidates_for_wal_and_shm()
    {
        using var fixture = new TemporaryDirectory();
        var databasePath = Path.Combine(fixture.Path, "state.vscdb");
        await File.WriteAllTextAsync(databasePath, "db");
        var memo = new IncrementalSourceMemo<int>();
        var value = 0;

        async Task<int> Parse(CancellationToken cancellationToken)
        {
            await Task.Yield();
            cancellationToken.ThrowIfCancellationRequested();
            return ++value;
        }

        var first = await memo.ResolveAsync(
            SourceFingerprint.ForSqlite(databasePath),
            Parse,
            default);
        var unchanged = await memo.ResolveAsync(
            SourceFingerprint.ForSqlite(databasePath),
            Parse,
            default);
        await File.WriteAllTextAsync(databasePath + "-wal", "wal");
        var walChanged = await memo.ResolveAsync(
            SourceFingerprint.ForSqlite(databasePath),
            Parse,
            default);
        await File.WriteAllTextAsync(databasePath + "-shm", "shm");
        var shmChanged = await memo.ResolveAsync(
            SourceFingerprint.ForSqlite(databasePath),
            Parse,
            default);

        Assert.Equal(1, first);
        Assert.Equal(1, unchanged);
        Assert.Equal(2, walChanged);
        Assert.Equal(3, shmChanged);
        Assert.Equal(3, memo.ParseCount);
    }

    [Fact]
    public async Task Stale_memo_never_reuses_value_across_credential_fingerprints()
    {
        var memo = new StaleAsyncMemo<string>(TimeSpan.FromMinutes(10));
        var now = DateTimeOffset.Parse("2026-07-26T12:00:00Z");

        var fresh = await memo.ResolveAsync(
            "sha256-account-a",
            now,
            static _ => Task.FromResult<string?>("account-a"),
            default);
        var stale = await memo.ResolveAsync(
            "sha256-account-a",
            now.AddMinutes(11),
            static _ => Task.FromResult<string?>(null),
            default);
        var otherAccount = await memo.ResolveAsync(
            "sha256-account-b",
            now.AddMinutes(12),
            static _ => Task.FromResult<string?>(null),
            default);

        Assert.Equal("account-a", fresh);
        Assert.Equal("account-a", stale);
        Assert.Null(otherAccount);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"amon-cache-tests-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
