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

    [Fact]
    public void V3IsAnAvailableSpriteVersionAndIsPreserved()
    {
        var store = new RecordingSettingsStore(
            new AppSettingsState(AutoUpdateEnabled: true));
        var viewModel = new SettingsViewModel(store);

        viewModel.PetSpriteVersion = 3;

        Assert.Contains(3, viewModel.PetSpriteVersions);
        Assert.Equal(3, viewModel.PetSpriteVersion);
        Assert.Equal(3, Assert.Single(store.Saved).PetSpriteVersion);
    }

    [Fact]
    public void ResetPetClearsOnlyCustomPathSoRuntimeCanUseBundledAmon()
    {
        var store = new RecordingSettingsStore(
            new AppSettingsState(
                AutoUpdateEnabled: true,
                PetSpritePath: "C:\\pets\\custom.webp",
                PetSpriteVersion: 2));
        var viewModel = new SettingsViewModel(store);

        viewModel.ResetPet();

        Assert.Empty(viewModel.PetSpritePath);
        Assert.Equal(2, viewModel.PetSpriteVersion);
        Assert.DoesNotContain(
            store.Saved,
            static saved => saved.PetSpritePath.Contains(
                "Assets",
                StringComparison.OrdinalIgnoreCase));
        Assert.Contains("amon 기본 펫", viewModel.PetImportStatus);
    }

    [Theory]
    [InlineData("127.0.0.1:3000")]
    [InlineData("localhost:3000")]
    [InlineData("http://127.0.0.1:3000")]
    [InlineData("https://monitor.example.com")]
    public void ReportIsConfiguredForSupportedServerAddresses(string serverUrl)
    {
        var store = new RecordingSettingsStore(new AppSettingsState(
            AutoUpdateEnabled: true,
            ServerUrl: serverUrl,
            UserKey: "amon_test_key"));
        var viewModel = new SettingsViewModel(store);

        Assert.True(viewModel.ReportConfigured);
    }

    [Theory]
    [InlineData("")]
    [InlineData("monitor.example.com")]
    [InlineData("ftp://monitor.example.com")]
    public void ReportRejectsUnsupportedServerAddresses(string serverUrl)
    {
        var store = new RecordingSettingsStore(new AppSettingsState(
            AutoUpdateEnabled: true,
            ServerUrl: serverUrl,
            UserKey: "amon_test_key"));
        var viewModel = new SettingsViewModel(store);

        Assert.False(viewModel.ReportConfigured);
    }

    private sealed class RecordingSettingsStore(AppSettingsState initial) : IAppSettingsStore
    {
        public List<AppSettingsState> Saved { get; } = [];

        public AppSettingsState Load() => initial;

        public void Save(AppSettingsState settings) => Saved.Add(settings);
    }
}
