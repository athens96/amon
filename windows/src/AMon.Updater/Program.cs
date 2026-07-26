using System.Diagnostics;
using System.Runtime.InteropServices;
using AMon.Update;

if (args.Length != 4 || args[0] != "--apply"
    || !int.TryParse(args[3], out var parentPid))
{
    return 2;
}

var archive = Path.GetFullPath(args[1]);
var destination = Path.GetFullPath(args[2]);

try
{
    try
    {
        using var parent = Process.GetProcessById(parentPid);
        await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(60));
    }
    catch (ArgumentException)
    {
        // The parent already exited.
    }

    ArchiveInstaller.InstallAndLaunch(
        archive,
        destination,
        Environment.ProcessPath
            ?? throw new InvalidOperationException("The updater path is unavailable."),
        VerifyAuthenticode,
        executable =>
        {
            _ = Process.Start(
                    new ProcessStartInfo(executable, "--show") { UseShellExecute = true })
                ?? throw new InvalidOperationException(
                    "The updated application could not start.");
        });
    return 0;
}
catch (Exception error)
{
    try
    {
        var log = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "A-mon", "update.log");
        Directory.CreateDirectory(Path.GetDirectoryName(log)!);
        await File.AppendAllTextAsync(log, $"{DateTimeOffset.UtcNow:O} {error}\n");
    }
    catch
    {
        // Update failures must not crash a second process while logging.
    }
    return 1;
}
finally
{
    ScheduleDetachedUpdaterCleanup();
}

static void VerifyAuthenticode(string executable)
{
    ExecutableArchitectureVerifier.Verify(
        executable, RuntimeInformation.ProcessArchitecture);
    using var process = Process.Start(new ProcessStartInfo("powershell.exe")
    {
        UseShellExecute = false,
        CreateNoWindow = true,
        ArgumentList =
        {
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "if ((Get-AuthenticodeSignature -LiteralPath $args[0]).Status -ne 'Valid') { exit 1 }",
            executable
        }
    }) ?? throw new InvalidOperationException("Authenticode verification could not start.");
    process.WaitForExit();
    if (process.ExitCode != 0)
        throw new InvalidDataException("The update executable has no valid Authenticode signature.");
}

static void ScheduleDetachedUpdaterCleanup()
{
    var executable = Environment.ProcessPath;
    if (!OperatingSystem.IsWindows()
        || string.IsNullOrWhiteSpace(executable)
        || !Path.GetFileName(executable).StartsWith(
            "AMon.Updater.detached-", StringComparison.OrdinalIgnoreCase))
    {
        return;
    }

    _ = NativeMethods.MoveFileEx(
        executable, null, NativeMethods.MoveFileDelayUntilReboot);
    var directory = Path.GetDirectoryName(executable);
    if (!string.IsNullOrWhiteSpace(directory)
        && Path.GetFileName(directory).StartsWith(
            ".amon-updater-", StringComparison.OrdinalIgnoreCase))
    {
        _ = NativeMethods.MoveFileEx(
            directory, null, NativeMethods.MoveFileDelayUntilReboot);
    }
}

internal static class NativeMethods
{
    internal const int MoveFileDelayUntilReboot = 0x4;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern bool MoveFileEx(
        string existingFileName, string? newFileName, int flags);
}
