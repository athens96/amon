using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AMon.WindowsPlatform;

public interface IWindowActivationService
{
    /// Bring the process's main window to the foreground. False when the process has no window,
    /// has exited, or (when `expectedName` is given) is no longer the process the caller recorded —
    /// pids are recycled. The caller then falls back to its own UI.
    bool TryActivateProcessWindow(int processId, string? expectedName = null);

    /// Bring the first windowed process with this image name to the foreground.
    bool TryActivateProcessNamed(string processName);
}

/// Restores a minimized window and asks for the foreground. Windows refuses foreground changes
/// from a background process in some situations; `SwitchToThisWindow` is the documented fallback
/// that still works from a tray app.
public sealed class WindowActivationService : IWindowActivationService
{
    private const int SwRestore = 9;

    public bool TryActivateProcessWindow(int processId, string? expectedName = null)
    {
        IntPtr handle;
        try
        {
            using var process = Process.GetProcessById(processId);
            if (process.HasExited)
                return false;
            if (expectedName is { Length: > 0 } && !string.Equals(process.ProcessName, expectedName, StringComparison.OrdinalIgnoreCase))
                return false;
            handle = process.MainWindowHandle;
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
        return Activate(handle);
    }

    public bool TryActivateProcessNamed(string processName)
    {
        Process[] processes;
        try
        {
            processes = Process.GetProcessesByName(processName);
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        try
        {
            foreach (var process in processes)
            {
                try
                {
                    if (!process.HasExited && Activate(process.MainWindowHandle))
                        return true;
                }
                catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                }
            }
            return false;
        }
        finally
        {
            foreach (var process in processes)
                process.Dispose();
        }
    }

    private static bool Activate(IntPtr handle)
    {
        if (handle == IntPtr.Zero)
            return false;
        if (IsIconic(handle))
            ShowWindow(handle, SwRestore);
        if (!SetForegroundWindow(handle))
            SwitchToThisWindow(handle, true);
        return true;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr windowHandle, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    private static extern void SwitchToThisWindow(IntPtr windowHandle, [MarshalAs(UnmanagedType.Bool)] bool altTab);
}
