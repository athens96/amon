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

    [Fact]
    public void TrayQuotaSelectionIsSavedUsingEmptyValueForAutomaticMode()
    {
        var store = new RecordingSettingsStore(
            new AppSettingsState(
                AutoUpdateEnabled: true,
                TrayQuotaProvider: "Codex"));
        var viewModel = new SettingsViewModel(store);

        viewModel.SelectedTrayQuotaProvider = "자동 선택";

        var saved = Assert.Single(store.Saved);
        Assert.Empty(saved.TrayQuotaProvider);
        Assert.Equal("자동 선택", viewModel.SelectedTrayQuotaProvider);
    }

    [Fact]
    public void ImportedPackageAppliesManifestSpriteVersion()
    {
        var store = new RecordingSettingsStore(
            new AppSettingsState(AutoUpdateEnabled: true));
        var viewModel = new SettingsViewModel(store);
        var result = new CodexPetImportResult(
            "C:\\pets\\spritesheet.webp",
            new CodexPetAssetMetadata(
                CodexPetAssetFormat.WebP,
                1536,
                2288,
                1234,
                2),
            "Svinushka");

        viewModel.ApplyImportedPet(result);

        Assert.Equal(2, viewModel.PetSpriteVersion);
        Assert.Equal(result.InstalledPath, viewModel.PetSpritePath);
        Assert.True(viewModel.PetEnabled);
        Assert.Contains("Svinushka", viewModel.PetImportStatus);
    }

    private sealed class RecordingSettingsStore(AppSettingsState initial) : IAppSettingsStore
    {
        public List<AppSettingsState> Saved { get; } = [];

        public AppSettingsState Load() => initial;

        public void Save(AppSettingsState settings) => Saved.Add(settings);
    }
}
