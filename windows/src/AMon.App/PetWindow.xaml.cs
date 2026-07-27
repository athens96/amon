using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls.Primitives;
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
    private System.Windows.Point _dragStartScreen;
    private System.Windows.Point _windowStart;
    private bool _isDragging;
    private bool _bubbleVisible = true;
    private double _bubbleWidth = 340;
    private double _bubbleHeight = 240;

    private const double BubbleMinimumWidth = 300;
    private const double BubbleMaximumWidth = 520;
    private const double BubbleMinimumHeight = 210;
    private const double BubbleMaximumHeight = 380;
    private const double PetOnlyWidth = 190;
    private const double BubbleWindowExtraWidth = 190;
    private const double WindowVerticalPadding = 32;

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
        {
            ApplyPresentation(announce: true);
        }
        else if (e.PropertyName is nameof(PetViewModel.HasCustomSprite)
                 or nameof(PetViewModel.SpritePath))
        {
            ApplyPresentation(announce: false);
        }
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
        var state = animationsEnabled && !_viewModel.HasCustomSprite
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

    private void OnAvatarMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _dragStartScreen = PointToScreen(e.GetPosition(this));
        _windowStart = new System.Windows.Point(Left, Top);
        _isDragging = false;
        AvatarButton.CaptureMouse();
        e.Handled = true;
    }

    private void OnAvatarMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!AvatarButton.IsMouseCaptured || e.LeftButton != MouseButtonState.Pressed)
            return;

        var current = PointToScreen(e.GetPosition(this));
        var delta = current - _dragStartScreen;
        if (!_isDragging
            && Math.Abs(delta.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(delta.Y) < SystemParameters.MinimumVerticalDragDistance)
        {
            return;
        }

        _isDragging = true;
        var workArea = SystemParameters.WorkArea;
        Left = Math.Clamp(_windowStart.X + delta.X, workArea.Left, workArea.Right - ActualWidth);
        Top = Math.Clamp(_windowStart.Y + delta.Y, workArea.Top, workArea.Bottom - ActualHeight);
        e.Handled = true;
    }

    private void OnAvatarMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!AvatarButton.IsMouseCaptured)
            return;

        AvatarButton.ReleaseMouseCapture();
        if (!_isDragging)
            SetBubbleVisible(!_bubbleVisible);
        e.Handled = true;
    }

    private void SetBubbleVisible(bool visible)
    {
        var right = Left + ActualWidth;
        _bubbleVisible = visible;
        var visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        ActivityBubble.Visibility = visibility;
        Width = visible ? _bubbleWidth + BubbleWindowExtraWidth : PetOnlyWidth;
        Height = visible
            ? Math.Max(220, _bubbleHeight + WindowVerticalPadding)
            : 220;
        Left = Math.Max(SystemParameters.WorkArea.Left, right - Width);
    }

    private void OnBubbleResize(object sender, DragDeltaEventArgs e)
    {
        _bubbleWidth = Math.Clamp(
            ActivityBubble.ActualWidth + e.HorizontalChange,
            BubbleMinimumWidth,
            BubbleMaximumWidth);
        _bubbleHeight = Math.Clamp(
            ActivityBubble.ActualHeight + e.VerticalChange,
            BubbleMinimumHeight,
            BubbleMaximumHeight);
        ActivityBubble.Width = _bubbleWidth;
        ActivityBubble.Height = _bubbleHeight;
        Width = _bubbleWidth + BubbleWindowExtraWidth;
        Height = Math.Max(220, _bubbleHeight + WindowVerticalPadding);

        var workArea = SystemParameters.WorkArea;
        Left = Math.Clamp(Left, workArea.Left, workArea.Right - Width);
        Top = Math.Clamp(Top, workArea.Top, workArea.Bottom - Height);
    }

    private void OnBubbleClick(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        DashboardToggleRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OnAvatarRightClick(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        ContextMenuRequested?.Invoke(this, EventArgs.Empty);
    }
}
