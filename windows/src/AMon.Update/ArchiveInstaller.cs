using System.IO.Compression;

namespace AMon.Update;

public static class ArchiveInstaller
{
    private const int MaximumEntries = 50_000;
    private const long MaximumExpandedBytes = 4L * 1024 * 1024 * 1024;

    public static void InstallAndLaunch(
        string archivePath,
        string applicationPath,
        string runningUpdaterPath,
        Action<string> verifyExecutable,
        Action<string> launchApplication)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(archivePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(applicationPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(runningUpdaterPath);
        ArgumentNullException.ThrowIfNull(verifyExecutable);
        ArgumentNullException.ThrowIfNull(launchApplication);

        var archive = Path.GetFullPath(archivePath);
        var application = Path.GetFullPath(applicationPath);
        var installDirectory = Path.GetDirectoryName(application)
            ?? throw new InvalidDataException("The application must have an installation directory.");
        var installParent = Directory.GetParent(installDirectory)?.FullName
            ?? throw new InvalidDataException("The installation directory cannot be a filesystem root.");
        var updater = Path.GetFullPath(runningUpdaterPath);

        if (!File.Exists(archive))
            throw new FileNotFoundException("The update archive was not found.", archive);
        if (!File.Exists(application))
            throw new FileNotFoundException("The installed application was not found.", application);
        if ((File.GetAttributes(installDirectory) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("A reparse-point installation directory cannot be updated.");
        if (IsWithin(updater, installDirectory))
            throw new InvalidOperationException(
                "The updater must run from outside the installation directory.");

        var transactionId = Guid.NewGuid().ToString("N");
        var stagedDirectory = Path.Combine(installParent, ".amon-stage-" + transactionId);
        var backupDirectory = Path.Combine(installParent, ".amon-backup-" + transactionId);
        var failedDirectory = Path.Combine(installParent, ".amon-failed-" + transactionId);
        var installedNewPayload = false;
        var movedExistingPayload = false;

        try
        {
            ExtractAndVerifyPayload(archive, stagedDirectory, verifyExecutable);

            Directory.Move(installDirectory, backupDirectory);
            movedExistingPayload = true;
            try
            {
                Directory.Move(stagedDirectory, installDirectory);
                installedNewPayload = true;
            }
            catch
            {
                Directory.Move(backupDirectory, installDirectory);
                movedExistingPayload = false;
                throw;
            }

            var installedApplication = Path.Combine(
                installDirectory, Path.GetFileName(application));
            if (!File.Exists(installedApplication))
                throw new InvalidDataException("The installed payload is missing A-mon.exe.");

            launchApplication(installedApplication);
            movedExistingPayload = false;
            TryDeleteDirectory(backupDirectory);
        }
        catch
        {
            if (installedNewPayload)
            {
                Directory.Move(installDirectory, failedDirectory);
                installedNewPayload = false;
            }

            if (movedExistingPayload && Directory.Exists(backupDirectory))
            {
                Directory.Move(backupDirectory, installDirectory);
                movedExistingPayload = false;
            }

            TryDeleteDirectory(failedDirectory);
            throw;
        }
        finally
        {
            TryDeleteDirectory(stagedDirectory);
        }
    }

    private static void ExtractAndVerifyPayload(
        string archivePath,
        string stagedDirectory,
        Action<string> verifyExecutable)
    {
        using var zip = ZipFile.OpenRead(archivePath);
        var files = ValidateEntries(zip);
        var applicationEntry = files.Single(file =>
            string.Equals(
                Path.GetFileName(file.Path),
                "A-mon.exe",
                StringComparison.OrdinalIgnoreCase));
        var payloadPrefix = Path.GetDirectoryName(applicationEntry.Path)
            ?.Replace(Path.DirectorySeparatorChar, '/')
            .Trim('/');
        payloadPrefix = string.IsNullOrEmpty(payloadPrefix) ? string.Empty : payloadPrefix + "/";

        if (files.Any(file =>
            !file.Path.StartsWith(payloadPrefix, StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidDataException(
                "Every update payload file must share the A-mon.exe directory.");
        }

        Directory.CreateDirectory(stagedDirectory);
        var stagedRoot = Path.GetFullPath(stagedDirectory)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        foreach (var file in files)
        {
            var relative = file.Path[payloadPrefix.Length..]
                .Replace('/', Path.DirectorySeparatorChar);
            var destination = Path.GetFullPath(Path.Combine(stagedDirectory, relative));
            if (!destination.StartsWith(stagedRoot, PathComparison))
                throw new InvalidDataException("The update archive contains an unsafe path.");

            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using var source = file.Entry.Open();
            using var output = new FileStream(
                destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            source.CopyTo(output);
        }

        foreach (var executable in Directory.EnumerateFiles(
                     stagedDirectory, "*.exe", SearchOption.AllDirectories))
        {
            verifyExecutable(executable);
        }
    }

    private static IReadOnlyList<ValidatedEntry> ValidateEntries(ZipArchive zip)
    {
        if (zip.Entries.Count > MaximumEntries)
            throw new InvalidDataException("The update archive contains too many entries.");

        var files = new List<ValidatedEntry>();
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long expandedBytes = 0;
        foreach (var entry in zip.Entries)
        {
            if (IsLink(entry))
                throw new InvalidDataException("The update archive cannot contain links.");

            var path = NormalizeEntryPath(entry.FullName);
            var isDirectory = entry.FullName.EndsWith("/", StringComparison.Ordinal)
                || entry.FullName.EndsWith("\\", StringComparison.Ordinal);
            if (isDirectory)
                continue;
            if (string.IsNullOrEmpty(path))
                throw new InvalidDataException("The update archive contains an empty file path.");
            if (!paths.Add(path))
                throw new InvalidDataException("The update archive contains duplicate file paths.");

            expandedBytes = checked(expandedBytes + entry.Length);
            if (expandedBytes > MaximumExpandedBytes)
                throw new InvalidDataException("The expanded update archive is too large.");
            files.Add(new ValidatedEntry(path, entry));
        }

        if (files.Count(file => string.Equals(
                Path.GetFileName(file.Path),
                "A-mon.exe",
                StringComparison.OrdinalIgnoreCase)) != 1)
        {
            throw new InvalidDataException(
                "The update archive must contain exactly one A-mon.exe.");
        }

        return files;
    }

    private static string NormalizeEntryPath(string entryPath)
    {
        if (string.IsNullOrWhiteSpace(entryPath))
            return string.Empty;

        var normalized = entryPath.Replace('\\', '/');
        if (normalized.StartsWith("/", StringComparison.Ordinal)
            || (normalized.Length >= 2 && char.IsAsciiLetter(normalized[0])
                && normalized[1] == ':'))
        {
            throw new InvalidDataException("The update archive contains an absolute path.");
        }

        var segments = normalized.Split('/', StringSplitOptions.RemoveEmptyEntries);
        foreach (var segment in segments)
        {
            if (segment is "." or ".."
                || segment.Contains(':')
                || segment.EndsWith(' ')
                || segment.EndsWith('.'))
            {
                throw new InvalidDataException("The update archive contains an unsafe path.");
            }
        }

        return string.Join('/', segments);
    }

    private static bool IsLink(ZipArchiveEntry entry)
    {
        const int unixFileTypeMask = 0xF000;
        const int unixSymbolicLink = 0xA000;
        var unixMode = (entry.ExternalAttributes >> 16) & unixFileTypeMask;
        var windowsAttributes = (FileAttributes)(entry.ExternalAttributes & 0xFFFF);
        return unixMode == unixSymbolicLink
            || (windowsAttributes & FileAttributes.ReparsePoint) != 0;
    }

    private static bool IsWithin(string path, string directory)
    {
        var root = Path.GetFullPath(directory)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        return Path.GetFullPath(path).StartsWith(root, PathComparison);
    }

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;

    private static void TryDeleteDirectory(string directory)
    {
        try
        {
            if (Directory.Exists(directory))
                Directory.Delete(directory, recursive: true);
        }
        catch
        {
            // A successful install must not be rolled back only because cleanup was blocked.
        }
    }

    private sealed record ValidatedEntry(string Path, ZipArchiveEntry Entry);
}
