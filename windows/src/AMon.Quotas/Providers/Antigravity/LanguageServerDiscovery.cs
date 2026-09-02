using System.Globalization;

namespace AMon.Quotas.Providers.Antigravity;

/// What to look for:
/// - `ProcessName`: executable to match (e.g. `language_server`, `agy`), with or without `.exe`.
/// - `Markers`: values matched against `--app_data_dir` / `--ide_name` / `--override_ide_name`
///   (exact, case-insensitive), falling back to a `/marker/` path substring. Empty matches any.
/// - `CsrfFlag`: flag whose value is the CSRF token. Empty means the process has none.
/// - `PortFlag`: optional flag carrying an HTTP fallback port (`--extension_server_port`).
public sealed record LanguageServerOptions(
    string ProcessName,
    IReadOnlyList<string> Markers,
    string CsrfFlag,
    string? PortFlag);

public sealed record LanguageServerResult(int Pid, string Csrf, IReadOnlyList<int> Ports, int? ExtensionPort);

/// Finds a running Codeium-derived language server (Antigravity's bundled `language_server`, or the
/// `agy` CLI) and returns the CSRF token + listening ports needed to call its local Connect-RPC
/// service.
///
/// Port of the macOS discovery onto Windows data sources: PowerShell's `Win32_Process` stands in for
/// `ps -ax -o pid=,command=` (same `pid command` shape) and `netstat -ano -p tcp` for `lsof`.
public sealed class LanguageServerDiscovery(IProcessRunner processRunner)
{
    public const string PowerShellExecutable = "powershell.exe";
    public const string NetstatExecutable = "netstat.exe";

    /// `Get-CimInstance Win32_Process` rendered as `pid command`, the shape `RankedCandidates` parses.
    /// Written through `[Console]::Out` rather than the pipeline: PowerShell's default formatter
    /// hard-wraps long strings at the console width when stdout is redirected, which would split a
    /// language server's `--csrf_token` onto a continuation line and hide it from `ExtractFlag`.
    public const string ProcessListScript =
        "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine } | "
        + "ForEach-Object { [Console]::Out.WriteLine(('{0} {1}' -f $_.ProcessId, $_.CommandLine)) }";

    private static readonly TimeSpan SubprocessTimeout = TimeSpan.FromSeconds(5);

    public async Task<LanguageServerResult?> DiscoverAsync(LanguageServerOptions options, CancellationToken cancellationToken)
    {
        var processes = await RunAsync(
            PowerShellExecutable,
            ["-NoProfile", "-NonInteractive", "-Command", ProcessListScript],
            cancellationToken);
        if (processes is null)
            return null;

        var candidates = RankedCandidates(processes.StandardOutput, options);
        if (candidates.Count == 0)
            return null;

        var netstat = await RunAsync(NetstatExecutable, ["-ano", "-p", "tcp"], cancellationToken);

        foreach (var candidate in candidates)
        {
            string csrf;
            if (string.IsNullOrWhiteSpace(options.CsrfFlag))
            {
                csrf = string.Empty;
            }
            else if (ExtractFlag(candidate.Command, options.CsrfFlag) is { } value)
            {
                csrf = value;
            }
            else
            {
                continue;
            }

            int? extensionPort = null;
            if (options.PortFlag is { } portFlag
                && ExtractFlag(candidate.Command, portFlag) is { } rawPort
                && int.TryParse(rawPort, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedPort))
            {
                extensionPort = parsedPort;
            }

            var ports = netstat is null ? [] : ParseListeningPorts(netstat.StandardOutput, candidate.Pid);
            if (ports.Count == 0 && extensionPort is null)
                continue;

            return new LanguageServerResult(candidate.Pid, csrf, ports, extensionPort);
        }

        return null;
    }

    private async Task<ProcessRunResult?> RunAsync(string executable, IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        try
        {
            var result = await processRunner.RunAsync(executable, arguments, SubprocessTimeout, cancellationToken);
            return result is { Succeeded: true } ? result : null;
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            return null;
        }
    }

    // MARK: - Pure helpers (unit-tested directly)

    /// Parse `pid command` lines into the candidates matching the process + markers, sorted by marker
    /// rank (exact flag match before path-substring match).
    public static IReadOnlyList<(int Pid, string Command)> RankedCandidates(string processList, LanguageServerOptions options)
    {
        var processNameLower = TrimExecutableSuffix(options.ProcessName.Trim().ToLowerInvariant());
        var markersLower = options.Markers
            .Select(marker => marker.Trim().ToLowerInvariant())
            .Where(marker => marker.Length > 0)
            .ToArray();

        var ranked = new List<(int Rank, int Pid, string Command)>();
        foreach (var rawLine in processList.Split('\n'))
        {
            var line = rawLine.Trim();
            var separator = line.IndexOfAny([' ', '\t']);
            if (line.Length == 0 || separator <= 0)
                continue;
            if (!int.TryParse(line[..separator], NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid))
                continue;
            var command = line[(separator + 1)..].Trim();
            if (!CommandMatchesProcess(command, processNameLower) || MarkerRank(command, markersLower) is not { } rank)
                continue;
            ranked.Add((rank, pid, command));
        }

        return ranked
            .OrderBy(candidate => candidate.Rank)
            .Select(candidate => (candidate.Pid, candidate.Command))
            .ToArray();
    }

    /// Extract the value of a CLI flag from a command string. Handles `--flag value` and `--flag=value`.
    public static string? ExtractFlag(string command, string flag)
    {
        var parts = command.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var flagEquals = flag + "=";
        for (var index = 0; index < parts.Length; index++)
        {
            if (parts[index] == flag)
            {
                if (index + 1 < parts.Length)
                    return parts[index + 1];
            }
            else if (parts[index].StartsWith(flagEquals, StringComparison.Ordinal))
            {
                return parts[index][flagEquals.Length..];
            }
        }
        return null;
    }

    /// Marker match priority: exact `--ide_name` / `--override_ide_name` / `--app_data_dir` value
    /// (rank 0, prevents "antigravity" matching "antigravity-next"); else a `/marker/` path substring
    /// (rank 1). No markers means match any instance (rank 0). Null when nothing matches.
    public static int? MarkerRank(string command, IReadOnlyList<string> markersLower)
    {
        if (markersLower.Count == 0)
            return 0;

        var ideName = ExtractFlag(command, "--ide_name")?.ToLowerInvariant();
        var overrideIdeName = ExtractFlag(command, "--override_ide_name")?.ToLowerInvariant();
        var appData = ExtractFlag(command, "--app_data_dir")?.ToLowerInvariant();
        if (ideName is not null || overrideIdeName is not null || appData is not null)
        {
            var matched = markersLower.Any(marker => ideName == marker || overrideIdeName == marker || appData == marker);
            return matched ? 0 : null;
        }

        // Windows command lines use backslashes; normalize so the `/marker/` probe still applies.
        var commandLower = NormalizeSeparators(command);
        return markersLower.Any(marker => commandLower.Contains($"/{marker}/", StringComparison.Ordinal)) ? 1 : null;
    }

    /// First argv token, honoring a quoted executable path.
    public static string Argv0(string command)
    {
        var trimmed = command.TrimStart(' ', '\t');
        if (trimmed.Length == 0)
            return string.Empty;
        var quote = trimmed[0];
        if (quote is '"' or '\'')
        {
            var end = trimmed.IndexOf(quote, 1);
            if (end > 0)
                return trimmed[1..end];
        }
        var separator = trimmed.IndexOf(' ');
        return separator < 0 ? trimmed : trimmed[..separator];
    }

    public static bool CommandMatchesProcess(string command, string processNameLower)
    {
        if (string.IsNullOrEmpty(processNameLower))
            return false;

        var executable = TrimExecutableSuffix(LastPathComponent(Argv0(command)).ToLowerInvariant());
        if (executable == processNameLower)
            return true;

        var commandLower = NormalizeSeparators(command);
        if (processNameLower.Length >= 8)
        {
            // e.g. `language_server_windows_x64.exe` for `language_server`.
            return executable.StartsWith($"{processNameLower}_", StringComparison.Ordinal)
                || commandLower.Contains(processNameLower, StringComparison.Ordinal);
        }
        foreach (var name in (string[])[processNameLower, $"{processNameLower}.exe"])
        {
            if (commandLower.EndsWith($"/{name}", StringComparison.Ordinal)
                || commandLower.Contains($"/{name} ", StringComparison.Ordinal)
                || commandLower.Contains($"/{name}\t", StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    /// Parse listening port numbers owned by `pid` from `netstat -ano -p tcp` output, e.g.
    /// `  TCP    127.0.0.1:52168    0.0.0.0:0    LISTENING    1234` (deduped, ascending).
    public static IReadOnlyList<int> ParseListeningPorts(string output, int pid)
    {
        var owner = pid.ToString(CultureInfo.InvariantCulture);
        var ports = new SortedSet<int>();
        foreach (var line in output.Split('\n'))
        {
            var columns = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (columns.Length < 4 || columns[^1] != owner)
                continue;
            if (!columns.Any(column => column.Equals("LISTENING", StringComparison.OrdinalIgnoreCase)))
                continue;
            var address = columns[1];
            var colon = address.LastIndexOf(':');
            if (colon < 0)
                continue;
            if (int.TryParse(address[(colon + 1)..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var port)
                && port is > 0 and < 65_536)
            {
                ports.Add(port);
            }
        }
        return [.. ports];
    }

    private static string NormalizeSeparators(string command) =>
        command.ToLowerInvariant().Replace('\\', '/');

    private static string LastPathComponent(string path)
    {
        var separator = path.LastIndexOfAny(['/', '\\']);
        return separator < 0 ? path : path[(separator + 1)..];
    }

    private static string TrimExecutableSuffix(string name) =>
        name.EndsWith(".exe", StringComparison.Ordinal) ? name[..^4] : name;
}
