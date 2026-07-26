using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using AMon.LocalData;
using AMon.Update;

namespace AMon.App;

internal sealed class UpdateCoordinator : IDisposable
{
    private readonly ConfigStore _configStore = new();
    private readonly UpdateService _updates = new(new HttpClient
    {
        Timeout = TimeSpan.FromMinutes(2)
    });
    private readonly CancellationTokenSource _shutdown = new();
    private readonly Func<Task> _shutdownApp;
    private Task? _loop;

    public UpdateCoordinator(Func<Task> shutdownApp) => _shutdownApp = shutdownApp;

    public void Start()
    {
        CleanupDetachedUpdaterDirectories();
        _loop ??= RunAsync(_shutdown.Token);
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        await Task.Delay(TimeSpan.FromSeconds(15), cancellationToken);
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var config = await _configStore.LoadAsync(cancellationToken);
                if (config.AutoUpdateEnabled && !string.IsNullOrWhiteSpace(config.ServerUrl))
                {
                    var current = Assembly.GetExecutingAssembly().GetName().Version
                        ?? new Version(0, 0, 0);
                    var staging = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "A-mon", "updates");
                    var result = await _updates.PrepareAutomaticUpdateAsync(
                        true, config.ServerUrl, current, staging, cancellationToken);
                    if (result.Outcome == AutomaticUpdateOutcome.Ready)
                    {
                        await ApplyAsync(result.StagedPath!);
                        return;
                    }
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch
            {
                // Offline and malformed release failures are retried on the next interval.
            }
            await Task.Delay(TimeSpan.FromMinutes(10), cancellationToken);
        }
    }

    private async Task ApplyAsync(string stagedArchive)
    {
        var application = Environment.ProcessPath
            ?? throw new InvalidOperationException("The application path is unavailable.");
        var helper = Path.Combine(AppContext.BaseDirectory, "AMon.Updater.exe");
        if (!File.Exists(helper))
            throw new FileNotFoundException("The updater helper is unavailable.", helper);
        var detachedDirectory = Path.Combine(
            Path.GetTempPath(),
            ".amon-updater-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(detachedDirectory);
        var detachedHelper = Path.Combine(
            detachedDirectory,
            "AMon.Updater.detached-" + Guid.NewGuid().ToString("N") + ".exe");
        File.Copy(helper, detachedHelper, overwrite: false);
        try
        {
            _ = Process.Start(
                    new ProcessStartInfo(detachedHelper)
                    {
                        UseShellExecute = false,
                        ArgumentList =
                        {
                            "--apply", stagedArchive, application,
                            Environment.ProcessId.ToString(
                                System.Globalization.CultureInfo.InvariantCulture)
                        }
                    })
                ?? throw new InvalidOperationException(
                    "The updater helper could not start.");
        }
        catch
        {
            File.Delete(detachedHelper);
            Directory.Delete(detachedDirectory);
            throw;
        }
        await _shutdownApp();
    }

    private static void CleanupDetachedUpdaterDirectories()
    {
        try
        {
            var cutoff = DateTime.UtcNow.Subtract(TimeSpan.FromDays(1));
            foreach (var directory in Directory.EnumerateDirectories(
                         Path.GetTempPath(), ".amon-updater-*", SearchOption.TopDirectoryOnly))
            {
                try
                {
                    if (Directory.GetLastWriteTimeUtc(directory) < cutoff)
                        Directory.Delete(directory, recursive: true);
                }
                catch
                {
                    // A running helper or endpoint protection can temporarily hold the file.
                }
            }
        }
        catch
        {
            // Temp cleanup must never disable update checks.
        }
    }

    public void Dispose()
    {
        _shutdown.Cancel();
        _shutdown.Dispose();
    }
}
