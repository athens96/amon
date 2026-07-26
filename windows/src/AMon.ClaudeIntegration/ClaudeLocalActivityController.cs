namespace AMon.ClaudeIntegration;

public sealed record ClaudeLocalActivityResult(
    bool Enabled,
    bool HookChanged,
    int PurgedFiles,
    IReadOnlyList<string> Errors);

public sealed class ClaudeLocalActivityController
{
    private readonly ClaudeHookInstaller installer;
    private readonly ClaudeLiveDataStore liveData;

    public ClaudeLocalActivityController(
        ClaudeHookInstaller? installer = null,
        ClaudeLiveDataStore? liveData = null)
    {
        this.installer = installer ?? new ClaudeHookInstaller();
        this.liveData = liveData ?? new ClaudeLiveDataStore();
    }

    public ClaudeLocalActivityResult Configure(
        bool enabled,
        string? hookExecutablePath)
    {
        var errors = new List<string>();
        var hookChanged = false;
        var purgedFiles = 0;

        if (enabled)
        {
            Try(errors, () => liveData.Enable());
            if (!string.IsNullOrWhiteSpace(hookExecutablePath)
                && File.Exists(hookExecutablePath))
            {
                Try(errors, () =>
                {
                    hookChanged = installer.Install(hookExecutablePath).Changed;
                });
            }
        }
        else
        {
            Try(errors, () =>
            {
                hookChanged = installer.Uninstall().Changed;
            });
            Try(errors, () =>
            {
                purgedFiles = liveData.DisableAndPurge();
            });
        }

        return new ClaudeLocalActivityResult(
            enabled,
            hookChanged,
            purgedFiles,
            errors);
    }

    private static void Try(List<string> errors, Action action)
    {
        try
        {
            action();
        }
        catch (Exception exception)
        {
            errors.Add(exception.Message);
        }
    }
}
