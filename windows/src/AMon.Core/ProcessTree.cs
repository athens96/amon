using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace AMon.Core;

/// One process in a snapshot of the process table.
public sealed record ProcessEntry(int ProcessId, int ParentProcessId, string Name);

/// A point-in-time view of the process table, enough to walk parent chains. Windows fills it from
/// a Toolhelp snapshot; tests build it by hand.
public sealed class ProcessTree(IReadOnlyDictionary<int, ProcessEntry> entries)
{
    public IReadOnlyDictionary<int, ProcessEntry> Entries { get; } = entries;

    public ProcessEntry? Find(int processId) =>
        Entries.TryGetValue(processId, out var entry) ? entry : null;

    /// Ancestors of `processId`, nearest first, stopping at the root or a cycle (pids recycle).
    public IEnumerable<ProcessEntry> Ancestors(int processId, int maxDepth = 15)
    {
        var seen = new HashSet<int> { processId };
        var current = Find(processId);
        for (var depth = 0; depth < maxDepth && current is not null; depth++)
        {
            var parent = current.ParentProcessId;
            if (parent <= 0 || !seen.Add(parent))
                yield break;
            current = Find(parent);
            if (current is null)
                yield break;
            yield return current;
        }
    }

    public IEnumerable<ProcessEntry> Named(string name) =>
        Entries.Values.Where(entry => string.Equals(entry.Name, name, StringComparison.OrdinalIgnoreCase));

    /// A snapshot of every process visible to the caller; empty off Windows or on failure.
    public static ProcessTree Snapshot()
    {
        if (!OperatingSystem.IsWindows())
            return new ProcessTree(new Dictionary<int, ProcessEntry>());
        return new ProcessTree(SnapshotOnWindows());
    }

    [SupportedOSPlatform("windows")]
    private static Dictionary<int, ProcessEntry> SnapshotOnWindows()
    {
        var entries = new Dictionary<int, ProcessEntry>();
        var snapshot = NativeMethods.CreateToolhelp32Snapshot(NativeMethods.SnapProcess, 0);
        if (snapshot == IntPtr.Zero || snapshot == NativeMethods.InvalidHandle)
            return entries;
        try
        {
            var entry = new NativeMethods.ProcessEntry32 { dwSize = (uint)Marshal.SizeOf<NativeMethods.ProcessEntry32>() };
            if (!NativeMethods.Process32First(snapshot, ref entry))
                return entries;
            do
            {
                var name = entry.szExeFile ?? string.Empty;
                if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                    name = name[..^4];
                entries[(int)entry.th32ProcessID] = new ProcessEntry((int)entry.th32ProcessID, (int)entry.th32ParentProcessID, name);
            }
            while (NativeMethods.Process32Next(snapshot, ref entry));
        }
        finally
        {
            NativeMethods.CloseHandle(snapshot);
        }
        return entries;
    }

    private static class NativeMethods
    {
        public const uint SnapProcess = 0x00000002;
        public static readonly IntPtr InvalidHandle = new(-1);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct ProcessEntry32
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

        [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool Process32First(IntPtr snapshot, ref ProcessEntry32 entry);

        [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry32 entry);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}

/// The GUI application that hosts a CLI session: the nearest ancestor of the CLI process that owns
/// a top-level window (Windows Terminal, VS Code, Cursor, …). Ported from the macOS
/// `HostProcessScanner` / hook `detect_host`, with "owns a window" standing in for ".app bundle".
public static class HostProcessScanner
{
    public sealed record Candidate(string HostApp, int HostProcessId);

    /// The nearest windowed ancestor of `processId`, or `null`.
    public static Candidate? HostOf(ProcessTree tree, int processId, Func<int, bool> ownsWindow)
    {
        foreach (var ancestor in tree.Ancestors(processId))
        {
            if (ancestor.ProcessId <= 4 || string.IsNullOrEmpty(ancestor.Name))
                continue;
            if (IsNeverAHost(ancestor.Name))
                continue;
            if (ownsWindow(ancestor.ProcessId))
                return new Candidate(ancestor.Name, ancestor.ProcessId);
        }
        return null;
    }

    /// Hosts of every live CLI process named `processName` (`claude`, `codex`).
    public static IReadOnlyList<Candidate> Candidates(ProcessTree tree, string processName, Func<int, bool> ownsWindow) =>
        tree.Named(processName)
            .Select(process => HostOf(tree, process.ProcessId, ownsWindow))
            .Where(static candidate => candidate is not null)
            .Select(static candidate => candidate!)
            .ToArray();

    /// Which candidate to jump to: only when every candidate points at the same host app —
    /// several different hosts means no guess is made. Unlike macOS, Windows offers no cheap way
    /// to read another process's working directory, so there is no cwd match here.
    public static Candidate? Select(IReadOnlyList<Candidate> candidates)
    {
        var hosts = candidates.Select(static candidate => candidate.HostApp).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        return hosts.Length == 1 ? candidates[0] : null;
    }

    /// Windows: does the process own a top-level window right now?
    public static bool OwnsTopLevelWindow(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return !process.HasExited && process.MainWindowHandle != IntPtr.Zero;
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    /// Shells, CLI runtimes, and the desktop/system processes above a console-launched shell are
    /// never the host, even though some of them (explorer's desktop) own a top-level window.
    private static bool IsNeverAHost(string name) =>
        name.ToLowerInvariant() is "cmd" or "powershell" or "pwsh" or "bash" or "sh" or "zsh" or "node"
            or "conhost" or "openconsole" or "claude" or "codex"
            or "explorer" or "dwm" or "sihost" or "taskhostw" or "svchost" or "services" or "wininit" or "winlogon"
            or "runtimebroker" or "applicationframehost";
}
