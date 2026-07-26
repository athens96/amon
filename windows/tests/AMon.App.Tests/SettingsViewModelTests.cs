using AMon.App.Settings;
using AMon.App.ViewModels;

namespace AMon.App.Tests;

public sealed class SettingsViewModelTests
{
    [Fact]
    public void AutoUpdateIsEnabledByDefault()
    {
        var store = new RecordingSettingsStore(new AppSettingsState(AutoUpdateEnabled: true));

        var viewModel = new SettingsViewModel(store);

        Assert.True(viewModel.AutoUpdateEnabled);
        Assert.Empty(store.Saved);
    }

    [Fact]
    public void AutoUpdateChangeIsSavedImmediately()
    {
        var store = new RecordingSettingsStore(new AppSettingsState(AutoUpdateEnabled: true));
        var viewModel = new SettingsViewModel(store);

        viewModel.AutoUpdateEnabled = false;

        var saved = Assert.Single(store.Saved);
        Assert.False(saved.AutoUpdateEnabled);
    }

    [Fact]
    public void AssigningTheSameValueDoesNotWriteAgain()
    {
        var store = new RecordingSettingsStore(new AppSettingsState(AutoUpdateEnabled: true));
        var viewModel = new SettingsViewModel(store);

        viewModel.AutoUpdateEnabled = true;

        Assert.Empty(store.Saved);
    }

    private sealed class RecordingSettingsStore(AppSettingsState initial) : IAppSettingsStore
    {
        public List<AppSettingsState> Saved { get; } = [];

        public AppSettingsState Load() => initial;

        public void Save(AppSettingsState settings) => Saved.Add(settings);
    }
}
