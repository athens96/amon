using System.Windows.Input;

namespace AMon.App.ViewModels;

public enum ShellPage
{
    Dashboard,
    Settings,
}

public sealed class ShellViewModel : ObservableObject
{
    private ShellPage _currentPage = ShellPage.Dashboard;

    public ShellViewModel(
        DashboardViewModel dashboard,
        SettingsViewModel settings)
    {
        Dashboard = dashboard ?? throw new ArgumentNullException(nameof(dashboard));
        Settings = settings ?? throw new ArgumentNullException(nameof(settings));
        ShowDashboardCommand = new RelayCommand(() => CurrentPage = ShellPage.Dashboard);
        ShowSettingsCommand = new RelayCommand(() => CurrentPage = ShellPage.Settings);
    }

    public DashboardViewModel Dashboard { get; }

    public SettingsViewModel Settings { get; }

    public ICommand ShowDashboardCommand { get; }

    public ICommand ShowSettingsCommand { get; }

    public ShellPage CurrentPage
    {
        get => _currentPage;
        private set
        {
            if (SetProperty(ref _currentPage, value))
            {
                OnPropertyChanged(nameof(IsDashboardVisible));
                OnPropertyChanged(nameof(IsSettingsVisible));
            }
        }
    }

    public bool IsDashboardVisible => CurrentPage == ShellPage.Dashboard;

    public bool IsSettingsVisible => CurrentPage == ShellPage.Settings;
}
