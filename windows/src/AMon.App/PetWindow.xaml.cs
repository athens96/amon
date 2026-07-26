using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using AMon.App.ViewModels;
using AMon.WindowsPlatform;

namespace AMon.App;

public partial class PetWindow : Window
{
    private readonly INativeWindowStyleService _nativeWindowStyleService;
    private PetViewModel? _viewModel;
    private string? _lastAnnouncementKey;
    private bool _systemParametersSubscribed;

    public PetWindow(INativeWindowStyleService nativeWindowStyleService)
    {
        _nativeWindowStyleService = nativeWindowStyleService
            ?? throw new ArgumentNullException(nameof(nativeWindowStyleService));
        InitializeComponent();
        SourceInitialized += OnSourceInitialized;
        DataContextChanged += OnDataContextChanged;
        IsVisibleChanged += OnIsVisibleChanged;
        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    public event EventHandler? DashboardToggleRequested;

    public event EventHandler? ContextMenuRequested;

    public void ShowNearWorkingArea()
    {
        var workArea = SystemParameters.WorkArea;
        Left = Math.Max(workArea.Left + 8, workArea.Right - Width - 20);
        Top = Math.Max(workArea.Top + 8, workArea.Bottom - Height - 20);
        Show();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (!_systemParametersSubscribed)
        {
            SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;
            _systemParametersSubscribed = true;
        }
        ApplyPresentation(announce: false);
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        if (_systemParametersSubscribed)
        {
            SystemParameters.StaticPropertyChanged -= OnSystemParametersChanged;
            _systemParametersSubscribed = false;
        }
        AttachViewModel(null);
        VisualStateManager.GoToElementState(AvatarVisual, "Still", false);
        SourceInitialized -= OnSourceInitialized;
        DataContextChanged -= OnDataContextChanged;
        IsVisibleChanged -= OnIsVisibleChanged;
        Loaded -= OnLoaded;
        Closed -= OnClosed;
    }

    private void OnSourceInitialized(object? sender, EventArgs e) =>
        _nativeWindowStyleService.MakeToolWindowNonActivating(this);

    private void OnDataContextChanged(
        object sender,
        DependencyPropertyChangedEventArgs e)
    {
        AttachViewModel(e.NewValue as PetViewModel);
        ApplyPresentation(announce: false);
    }

    private void AttachViewModel(PetViewModel? viewModel)
    {
        if (_viewModel is not null)
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        _viewModel = viewModel;
        if (_viewModel is not null)
            _viewModel.PropertyChanged += OnViewModelPropertyChanged;
    }

    private void OnViewModelPropertyChanged(
        object? sender,
        PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PetViewModel.Current))
            ApplyPresentation(announce: true);
    }

    private void OnSystemParametersChanged(
        object? sender,
        PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SystemParameters.ClientAreaAnimation))
            ApplyPresentation(announce: false);
    }

    private void OnIsVisibleChanged(
        object sender,
        DependencyPropertyChangedEventArgs e) =>
        ApplyPresentation(announce: false);

    private void ApplyPresentation(bool announce)
    {
        if (!IsLoaded || _viewModel is null)
            return;

        var animationsEnabled =
            IsVisible && SystemParameters.ClientAreaAnimation;
        var state = animationsEnabled
            ? _viewModel.Current.Status.ToString()
            : "Still";
        VisualStateManager.GoToElementState(
            AvatarVisual,
            state,
            useTransitions: animationsEnabled);

        AutomationProperties.SetLiveSetting(
            ActivityBubble,
            _viewModel.Current.IsAttention
                ? AutomationLiveSetting.Assertive
                : AutomationLiveSetting.Polite);

        var announcementKey =
            $"{_viewModel.Current.Status}|{_viewModel.Current.SessionIdentity}";
        if (!announce || string.Equals(
                announcementKey,
                _lastAnnouncementKey,
                StringComparison.Ordinal))
        {
            _lastAnnouncementKey = announcementKey;
            return;
        }

        _lastAnnouncementKey = announcementKey;
        var peer = UIElementAutomationPeer.FromElement(ActivityBubble)
            ?? UIElementAutomationPeer.CreatePeerForElement(ActivityBubble);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void OnAvatarClick(object sender, RoutedEventArgs e) =>
        DashboardToggleRequested?.Invoke(this, EventArgs.Empty);

    private void OnAvatarRightClick(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        ContextMenuRequested?.Invoke(this, EventArgs.Empty);
    }
}
