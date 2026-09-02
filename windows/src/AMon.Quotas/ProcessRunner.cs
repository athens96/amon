using System.Diagnostics;

namespace AMon.Quotas;

public sealed record ProcessRunResult(int ExitCode, string StandardOutput)
{
    public bool Succeeded => ExitCode == 0;
}

/// Subprocess seam for local discovery (finding a running language server and its ports).
public interface IProcessRunner
{
    Task<ProcessRunResult?> RunAsync(string executable, IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken cancellationToken);
}

public sealed class SystemProcessRunner : IProcessRunner
{
    public async Task<ProcessRunResult?> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo(executable)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments)
            startInfo.ArgumentList.Add(argument);

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
                return null;
            using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutSource.CancelAfter(timeout);
            var output = process.StandardOutput.ReadToEndAsync(timeoutSource.Token);
            var error = process.StandardError.ReadToEndAsync(timeoutSource.Token);
            try
            {
                await process.WaitForExitAsync(timeoutSource.Token);
            }
            catch (OperationCanceledException)
            {
                // A hung helper (PowerShell, netstat) must not be orphaned every refresh cycle.
                TryKill(process);
                return null;
            }
            var stdout = await output;
            await error;
            return new ProcessRunResult(process.ExitCode, stdout);
        }
        catch (Exception exception) when (exception is OperationCanceledException or IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
    }
}
