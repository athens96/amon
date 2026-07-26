using AMon.App.Settings;
using AMon.App.ViewModels;

namespace AMon.App.Tests;

public sealed class ShellViewModelTests
{
    [Fact]
    public void NavigationCommandsChangeTheVisiblePage()
    {
        var shell = new ShellViewModel(
            new DashboardViewModel(),
            new SessionHistoryViewModel(Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid():N}.json")),
            new SettingsViewModel(new InMemorySettingsStore()));

        Assert.True(shell.IsDashboardVisible);
        Assert.False(shell.IsSessionsVisible);
        Assert.False(shell.IsSettingsVisible);

        shell.ShowSessionsCommand.Execute(null);
        Assert.False(shell.IsDashboardVisible);
        Assert.True(shell.IsSessionsVisible);
        Assert.False(shell.IsSettingsVisible);

        shell.ShowSettingsCommand.Execute(null);
        Assert.False(shell.IsDashboardVisible);
        Assert.False(shell.IsSessionsVisible);
        Assert.True(shell.IsSettingsVisible);

        shell.ShowDashboardCommand.Execute(null);
        Assert.True(shell.IsDashboardVisible);
        Assert.False(shell.IsSessionsVisible);
        Assert.False(shell.IsSettingsVisible);
    }

    private sealed class InMemorySettingsStore : IAppSettingsStore
    {
        public AppSettingsState Load() => new(AutoUpdateEnabled: true);

        public void Save(AppSettingsState settings)
        {
        }
    }
}
