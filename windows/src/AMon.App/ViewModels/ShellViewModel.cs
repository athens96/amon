using System.Windows.Input;

namespace AMon.App.ViewModels;

public enum ShellPage
{
    Dashboard,
    Sessions,
    Settings,
}

public sealed class ShellViewModel : ObservableObject
{
    private ShellPage _currentPage = ShellPage.Dashboard;

    public ShellViewModel(
        DashboardViewModel dashboard,
        SessionHistoryViewModel sessions,
        SettingsViewModel settings)
    {
        Dashboard = dashboard ?? throw new ArgumentNullException(nameof(dashboard));
        Sessions = sessions ?? throw new ArgumentNullException(nameof(sessions));
        Settings = settings ?? throw new ArgumentNullException(nameof(settings));
        ShowDashboardCommand = new RelayCommand(() => CurrentPage = ShellPage.Dashboard);
        ShowSessionsCommand = new RelayCommand(() => CurrentPage = ShellPage.Sessions);
        ShowSettingsCommand = new RelayCommand(() => CurrentPage = ShellPage.Settings);
    }

    public DashboardViewModel Dashboard { get; }

    public SessionHistoryViewModel Sessions { get; }

    public SettingsViewModel Settings { get; }

    public ICommand ShowDashboardCommand { get; }

    public ICommand ShowSessionsCommand { get; }

    public ICommand ShowSettingsCommand { get; }

    public ShellPage CurrentPage
    {
        get => _currentPage;
        private set
        {
            if (SetProperty(ref _currentPage, value))
            {
                OnPropertyChanged(nameof(IsDashboardVisible));
                OnPropertyChanged(nameof(IsSessionsVisible));
                OnPropertyChanged(nameof(IsSettingsVisible));
            }
        }
    }

    public bool IsDashboardVisible => CurrentPage == ShellPage.Dashboard;

    public bool IsSessionsVisible => CurrentPage == ShellPage.Sessions;

    public bool IsSettingsVisible => CurrentPage == ShellPage.Settings;
}
