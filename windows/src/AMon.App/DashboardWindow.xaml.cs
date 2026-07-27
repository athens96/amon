using System.Diagnostics;
using System.IO;
using System.Windows;
using AMon.App.ViewModels;

namespace AMon.App;

public partial class DashboardWindow : Window
{
    public static readonly DependencyProperty PetViewModelProperty =
        DependencyProperty.Register(
            nameof(PetViewModel),
            typeof(PetViewModel),
            typeof(DashboardWindow));

    public DashboardWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => WindowsWindowStyle.Apply(this);
    }

    public PetViewModel? PetViewModel
    {
        get => (PetViewModel?)GetValue(PetViewModelProperty);
        set => SetValue(PetViewModelProperty, value);
    }

    private SettingsViewModel? Settings =>
        (DataContext as ShellViewModel)?.Settings;

    private void OnImportCodexPetClick(object sender, RoutedEventArgs e)
    {
        if (Settings is null)
            return;
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Codex 호환 펫 가져오기",
            Filter = "Codex 펫|*.zip;*.png;*.webp|ZIP 패키지|*.zip|PNG 이미지|*.png|WebP 이미지|*.webp",
            CheckFileExists = true,
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) != true)
            return;
        try
        {
            var result = CodexPetAssetService.Import(
                dialog.FileName,
                Settings.PetSpriteVersion);
            Settings.ApplyImportedPet(result);
        }
        catch (Exception exception) when (
            exception is IOException
                or InvalidDataException
                or UnauthorizedAccessException
                or NotSupportedException)
        {
            Settings.SetPetImportError(exception.Message);
        }
    }

    private void OnResetCodexPetClick(object sender, RoutedEventArgs e) =>
        Settings?.ResetPet();

    private void OnOpenCodexPetGalleryClick(object sender, RoutedEventArgs e) =>
        OpenPetLink("https://codex-pets.net/");

    private void OnOpenCodexPetSettingsClick(object sender, RoutedEventArgs e) =>
        OpenPetLink("codex://settings");

    private void OpenPetLink(string target)
    {
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception exception) when (
            exception is InvalidOperationException
                or System.ComponentModel.Win32Exception)
        {
            Settings?.SetPetImportError(
                $"링크를 열 수 없습니다: {exception.Message}");
        }
    }
}
