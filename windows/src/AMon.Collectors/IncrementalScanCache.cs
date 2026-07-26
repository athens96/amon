using System.Text;

namespace AMon.Collectors;

internal readonly record struct FileFingerprint(
    string CanonicalPath,
    long Length,
    long LastWriteTimeUtcTicks)
{
    public DateTimeOffset LastWriteTime =>
        new(LastWriteTimeUtcTicks, TimeSpan.Zero);

    public static bool TryCreate(string path, out FileFingerprint fingerprint)
    {
        fingerprint = default;
        try
        {
            var canonicalPath = Canonicalize(path);
            var info = new FileInfo(canonicalPath);
            if (!info.Exists)
                return false;

            fingerprint = new FileFingerprint(
                canonicalPath,
                info.Length,
                info.LastWriteTimeUtc.Ticks);
            return true;
        }
        catch (Exception exception) when (
            exception is IOException
                or UnauthorizedAccessException
                or NotSupportedException)
        {
            return false;
        }
    }

    public static string Canonicalize(string path)
    {
        var fullPath = Path.GetFullPath(path);
        try
        {
            return File.ResolveLinkTarget(fullPath, returnFinalTarget: true)?.FullName
                ?? fullPath;
        }
        catch (Exception exception) when (
            exception is IOException
                or UnauthorizedAccessException
                or NotSupportedException)
        {
            return fullPath;
        }
    }
}

internal sealed record CachedFile<T>(
    string Path,
    FileFingerprint Fingerprint,
    T Value);

internal sealed class IncrementalFileCache<T>
{
    private static readonly StringComparer PathComparer =
        OperatingSystem.IsWindows()
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<string, Entry> _entries = new(PathComparer);
    private int _parseCount;

    internal int ParseCount => Volatile.Read(ref _parseCount);

    internal int EntryCount
    {
        get
        {
            _gate.Wait();
            try
            {
                return _entries.Count;
            }
            finally
            {
                _gate.Release();
            }
        }
    }

    public async Task<IReadOnlyList<CachedFile<T>>> ResolveAsync(
        IEnumerable<string> paths,
        Func<string, CancellationToken, ValueTask<T>> parse,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var result = new List<CachedFile<T>>();
            var visited = new HashSet<string>(PathComparer);
            foreach (var path in paths)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var canonicalPath = FileFingerprint.Canonicalize(path);
                if (!visited.Add(canonicalPath))
                {
                    continue;
                }

                if (!FileFingerprint.TryCreate(canonicalPath, out var fingerprint))
                {
                    // The directory enumeration already proved that this path existed.
                    // A concurrent writer can make the subsequent stat fail briefly; keep
                    // the last normalized value for this scan and retry next time.
                    if (_entries.TryGetValue(canonicalPath, out var unavailableEntry))
                    {
                        result.Add(new CachedFile<T>(
                            canonicalPath,
                            unavailableEntry.Fingerprint,
                            unavailableEntry.Value));
                    }
                    continue;
                }

                if (!_entries.TryGetValue(fingerprint.CanonicalPath, out var entry) ||
                    entry.Fingerprint != fingerprint)
                {
                    var lastGood = entry;
                    try
                    {
                        var value = await parse(fingerprint.CanonicalPath, cancellationToken);
                        entry = new Entry(fingerprint, value);
                        _entries[fingerprint.CanonicalPath] = entry;
                        Interlocked.Increment(ref _parseCount);
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception exception) when (
                        exception is IOException
                            or UnauthorizedAccessException
                            or InvalidDataException)
                    {
                        if (lastGood is null)
                            continue;

                        // A writer can temporarily lock or replace a changed file. Keep
                        // serving the prior normalized contribution, but retain its old
                        // fingerprint so the next scan retries the parse.
                        entry = lastGood;
                    }
                }

                result.Add(new CachedFile<T>(
                    fingerprint.CanonicalPath,
                    fingerprint,
                    entry.Value));
            }

            foreach (var deleted in _entries.Keys.Where(path => !visited.Contains(path)).ToArray())
                _entries.Remove(deleted);

            return result;
        }
        finally
        {
            _gate.Release();
        }
    }

    internal void Reset()
    {
        _gate.Wait();
        try
        {
            _entries.Clear();
            Volatile.Write(ref _parseCount, 0);
        }
        finally
        {
            _gate.Release();
        }
    }

    private sealed record Entry(FileFingerprint Fingerprint, T Value);
}

internal readonly record struct SourceFingerprint(
    string CanonicalPath,
    string Signature)
{
    public static SourceFingerprint ForSqlite(string databasePath)
    {
        var canonical = FileFingerprint.Canonicalize(databasePath);
        var signature = new StringBuilder();
        foreach (var path in new[] { canonical, canonical + "-wal", canonical + "-shm" })
        {
            signature.Append(path).Append('\0');
            if (FileFingerprint.TryCreate(path, out var fingerprint))
            {
                signature
                    .Append(fingerprint.Length)
                    .Append(':')
                    .Append(fingerprint.LastWriteTimeUtcTicks);
            }
            else
            {
                signature.Append("missing");
            }
            signature.Append('\0');
        }
        return new SourceFingerprint(canonical, signature.ToString());
    }
}

internal sealed class IncrementalSourceMemo<T>
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private SourceFingerprint _fingerprint;
    private T? _value;
    private bool _hasValue;
    private int _parseCount;

    internal int ParseCount => Volatile.Read(ref _parseCount);

    public async Task<T> ResolveAsync(
        SourceFingerprint fingerprint,
        Func<CancellationToken, Task<T>> parse,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_hasValue && _fingerprint == fingerprint)
                return _value!;

            var value = await parse(cancellationToken);
            _fingerprint = fingerprint;
            _value = value;
            _hasValue = true;
            Interlocked.Increment(ref _parseCount);
            return value;
        }
        finally
        {
            _gate.Release();
        }
    }

    internal bool TryGetLastGood(out T value)
    {
        _gate.Wait();
        try
        {
            value = _value!;
            return _hasValue;
        }
        finally
        {
            _gate.Release();
        }
    }
}

internal sealed class StaleAsyncMemo<T>(TimeSpan timeToLive)
    where T : class
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _key;
    private DateTimeOffset _fetchedAt;
    private T? _value;
    private int _fetchCount;

    internal int FetchCount => Volatile.Read(ref _fetchCount);

    public async Task<T?> ResolveAsync(
        string key,
        DateTimeOffset now,
        Func<CancellationToken, Task<T?>> fetch,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var sameKey = string.Equals(_key, key, StringComparison.Ordinal);
            if (sameKey && _value is not null && now - _fetchedAt < timeToLive)
                return _value;

            Interlocked.Increment(ref _fetchCount);
            var refreshed = await fetch(cancellationToken);
            if (refreshed is not null)
            {
                _key = key;
                _fetchedAt = now;
                _value = refreshed;
                return refreshed;
            }

            // Never leak a prior credential's usage into a newly-authenticated account.
            return sameKey ? _value : null;
        }
        finally
        {
            _gate.Release();
        }
    }
}
