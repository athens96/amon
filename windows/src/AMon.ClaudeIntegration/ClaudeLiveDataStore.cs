using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace AMon.ClaudeIntegration;

public sealed class ClaudeLiveDataStore
{
    public const string DisabledMarkerName = ".local-activity-disabled";

    private static readonly Regex ManagedTombstoneName = new(
        @"^[A-Za-z0-9._-]{1,80}-[A-F0-9]{24}\.tombstone$",
        RegexOptions.CultureInvariant);
    private static readonly Regex ManagedSnapshotName = new(
        @"^[A-Za-z0-9._-]{1,80}-[A-F0-9]{24}\.json$",
        RegexOptions.CultureInvariant);
    private static readonly Regex ManagedSnapshotTemporaryName = new(
        @"^\.[A-Za-z0-9._-]{1,80}-[A-F0-9]{24}\.json\.\d+\.[A-Fa-f0-9]{32}\.tmp$",
        RegexOptions.CultureInvariant);
    private static readonly Regex ManagedTombstoneTemporaryName = new(
        @"^\.[A-Za-z0-9._-]{1,80}-[A-F0-9]{24}\.tombstone\.\d+\.[A-Fa-f0-9]{32}\.tmp$",
        RegexOptions.CultureInvariant);
    private readonly string liveDirectory;

    public ClaudeLiveDataStore(string? liveDirectory = null)
    {
        this.liveDirectory = Path.GetFullPath(
            liveDirectory ?? ResolveDefaultLiveDirectory());
    }

    public string DisabledMarkerPath =>
        Path.Combine(liveDirectory, DisabledMarkerName);

    public bool IsDisabled => File.Exists(DisabledMarkerPath);

    public void Enable()
    {
        using var mutation = AcquireMutationLock();
        File.Delete(DisabledMarkerPath);
    }

    public int DisableAndPurge()
    {
        using var mutation = AcquireMutationLock();
        WriteDisabledMarker();
        return PurgeManagedActivityLocked();
    }

    public int PurgeManagedActivity()
    {
        using var mutation = AcquireMutationLock();
        return PurgeManagedActivityLocked();
    }

    private int PurgeManagedActivityLocked()
    {
        if (!Directory.Exists(liveDirectory))
            return 0;

        var deleted = 0;
        foreach (var path in Enumerate(liveDirectory, "*.json"))
        {
            if (IsManagedSnapshot(path) && TryDelete(path))
                deleted++;
        }
        foreach (var path in Enumerate(liveDirectory, "*.tmp"))
        {
            if (ManagedSnapshotTemporaryName.IsMatch(Path.GetFileName(path))
                && TryDelete(path))
            {
                deleted++;
            }
        }

        var endedDirectory = Path.Combine(liveDirectory, ".ended");
        foreach (var path in Enumerate(endedDirectory, "*.tombstone"))
        {
            if (IsManagedTombstone(path) && TryDelete(path))
                deleted++;
        }
        foreach (var path in Enumerate(endedDirectory, "*.tmp"))
        {
            if (ManagedTombstoneTemporaryName.IsMatch(Path.GetFileName(path))
                && TryDelete(path))
            {
                deleted++;
            }
        }

        return deleted;
    }

    private ClaudeLiveMutationLock AcquireMutationLock() =>
        ClaudeLiveMutationLock.TryAcquire(
            liveDirectory,
            TimeSpan.FromSeconds(10))
        ?? throw new TimeoutException(
            "Timed out waiting to update Claude local activity data.");

    private static bool IsManagedSnapshot(string path) =>
        ManagedSnapshotName.IsMatch(Path.GetFileName(path));

    private static bool IsManagedTombstone(string path)
    {
        if (!ManagedTombstoneName.IsMatch(Path.GetFileName(path)))
            return false;
        try
        {
            var value = File.ReadAllText(path, Encoding.UTF8);
            return DateTimeOffset.TryParseExact(
                value,
                "O",
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out _);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private void WriteDisabledMarker()
    {
        Directory.CreateDirectory(liveDirectory);
        var temporary = Path.Combine(
            liveDirectory,
            $".{DisabledMarkerName}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.WriteThrough))
            using (var writer = new StreamWriter(
                stream,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)))
            {
                writer.Write("disabled");
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporary, DisabledMarkerPath, overwrite: true);
        }
        finally
        {
            TryDelete(temporary);
        }
    }

    private static string[] Enumerate(string directory, string pattern)
    {
        try
        {
            return Directory.Exists(directory)
                ? Directory.EnumerateFiles(
                    directory, pattern, SearchOption.TopDirectoryOnly).ToArray()
                : [];
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static bool TryDelete(string path)
    {
        try
        {
            File.Delete(path);
            return !File.Exists(path);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static string ResolveDefaultLiveDirectory()
    {
        var appData = Environment.GetFolderPath(
            Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(appData))
            appData = Environment.GetEnvironmentVariable("APPDATA");
        if (string.IsNullOrEmpty(appData))
            throw new InvalidOperationException("APPDATA is unavailable.");
        return Path.Combine(appData, "A-mon", "live");
    }

}
