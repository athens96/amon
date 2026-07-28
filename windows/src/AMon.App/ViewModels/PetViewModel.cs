using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows.Input;
using AMon.Activity;

namespace AMon.App.ViewModels;

public sealed class PetViewModel : ObservableObject
{
    private readonly ObservableCollection<PetPresentation> _presentations = [];
    private readonly RelayCommand _previousCommand;
    private readonly RelayCommand _nextCommand;
    private int _currentIndex;
    private bool _showsCurrentTask;
    private string _spritePath = string.Empty;
    private int _spriteVersion = 1;
    private bool _hasCustomSprite;
    private bool _hasSprite;
    private int _dragDirection;

    public PetViewModel(
        IEnumerable<PetPresentation>? presentations = null,
        bool showsCurrentTask = true)
    {
        _showsCurrentTask = showsCurrentTask;
        _previousCommand = new RelayCommand(Previous, () => HasRunningCarousel);
        _nextCommand = new RelayCommand(Next, () => HasRunningCarousel);
        PreviousCommand = _previousCommand;
        NextCommand = _nextCommand;
        UpdatePresentations(presentations?.ToArray() ?? []);
    }

    public IReadOnlyList<PetPresentation> Presentations => _presentations;

    public bool ShowsCurrentTask
    {
        get => _showsCurrentTask;
        private set => SetProperty(ref _showsCurrentTask, value);
    }

    public string SpritePath
    {
        get => _spritePath;
        private set => SetProperty(ref _spritePath, value);
    }

    /// <summary>True only for a user-imported sprite, never for bundled amon.</summary>
    public bool HasCustomSprite
    {
        get => _hasCustomSprite;
        private set
        {
            if (SetProperty(ref _hasCustomSprite, value))
                OnPropertyChanged(nameof(UsesBundledSprite));
        }
    }

    /// <summary>True when either a valid custom or bundled sprite can render.</summary>
    public bool HasSprite
    {
        get => _hasSprite;
        private set
        {
            if (SetProperty(ref _hasSprite, value))
                OnPropertyChanged(nameof(UsesBundledSprite));
        }
    }

    public bool UsesBundledSprite => HasSprite && !HasCustomSprite;

    public int SpriteVersion
    {
        get => _spriteVersion;
        private set => SetProperty(ref _spriteVersion, value);
    }

    /// <summary>-1 while dragging left, 1 while dragging right, otherwise 0.</summary>
    public int DragDirection
    {
        get => _dragDirection;
        private set => SetProperty(ref _dragDirection, value);
    }

    public ICommand PreviousCommand { get; }

    public ICommand NextCommand { get; }

    public int CurrentIndex
    {
        get => _currentIndex;
        private set
        {
            var normalized = NormalizeIndex(value);
            if (SetProperty(ref _currentIndex, normalized))
                RaiseCurrentProperties();
        }
    }

    public PetPresentation Current => _presentations[CurrentIndex];

    public string? SelectedSessionIdentity => Current.SessionIdentity;

    public bool HasRunningCarousel =>
        _presentations.Count > 1
        && _presentations.All(static item =>
            item.Status is PetActivityStatus.Running or PetActivityStatus.Reviewing);

    public string CounterText =>
        HasRunningCarousel ? $"{CurrentIndex + 1}/{_presentations.Count}" : string.Empty;

    public string AccessiblePositionText => HasRunningCarousel
        ? $"{_presentations.Count}개 동시 세션 중 {CurrentIndex + 1}번째, "
          + $"{Current.Provider}, {Current.Title}"
        : $"{Current.StatusText}, {Current.Title}";

    public string AccessibilityDescription =>
        $"amon 펫, {Current.StatusText}, {Current.Title}";

    public string InputTokenText => Current.InputTokens is { } value
        ? $"INPUT {FormatTokens(value)}"
        : "INPUT —";

    public string OutputTokenText => Current.OutputTokens is { } value
        ? $"OUTPUT {FormatTokens(value)}"
        : "OUTPUT —";

    public string TotalTokenText =>
        Current.InputTokens is null
        && Current.OutputTokens is null
        && Current.TotalTokens is { } value
            ? $"합계 {FormatTokens(value)}"
            : string.Empty;

    public string BubbleText => CompactPreview(Current.OutputText);

    public string InputBubbleText => CompactPreview(Current.InputText);

    public string OutputBubbleText => CompactPreview(Current.OutputText);

    public string TaskText => CompactPreview(Current.Title, 72);

    public bool HasTokenBreakdown =>
        Current.InputTokens is not null || Current.OutputTokens is not null;

    public double InputFraction => TokenFractions().Input;

    public double OutputFraction => TokenFractions().Output;

    public double RemainderFraction => TokenFractions().Remainder;

    public void UpdatePresentations(IReadOnlyList<PetPresentation> presentations)
    {
        ArgumentNullException.ThrowIfNull(presentations);
        var previousIdentity = CurrentOrNull()?.SessionIdentity;
        var previousIndex = _currentIndex;

        _presentations.Clear();
        foreach (var presentation in presentations)
            _presentations.Add(presentation);
        if (_presentations.Count == 0)
            _presentations.Add(PetPresentation.Idle);

        var preservedIndex = -1;
        if (previousIdentity is not null)
        {
            for (var index = 0; index < _presentations.Count; index++)
            {
                if (!string.Equals(
                        _presentations[index].SessionIdentity,
                        previousIdentity,
                        StringComparison.Ordinal))
                    continue;
                preservedIndex = index;
                break;
            }
        }
        _currentIndex = preservedIndex >= 0
            ? preservedIndex
            : Math.Clamp(previousIndex, 0, _presentations.Count - 1);

        OnPropertyChanged(nameof(Presentations));
        RaiseCurrentProperties();
        _previousCommand.NotifyCanExecuteChanged();
        _nextCommand.NotifyCanExecuteChanged();
    }

    public void ConfigureAppearance(
        bool showsCurrentTask,
        string? spritePath,
        int spriteVersion = 1,
        string? bundledSpritePath = null,
        Func<string?, int, bool>? isValidSprite = null)
    {
        ShowsCurrentTask = showsCurrentTask;
        var selection = BundledPetSprite.Resolve(
            spritePath,
            spriteVersion,
            bundledSpritePath,
            isValidSprite);
        SpriteVersion = selection?.Version ?? BundledPetSprite.Version;
        SpritePath = selection?.Path ?? string.Empty;
        HasCustomSprite = selection?.IsCustom == true;
        HasSprite = selection is not null;
    }

    public void SetDragDirection(double horizontalDelta) =>
        DragDirection = horizontalDelta switch
        {
            > 0 => 1,
            < 0 => -1,
            _ => 0,
        };

    private void Previous() => CurrentIndex--;

    private void Next() => CurrentIndex++;

    private PetPresentation? CurrentOrNull() =>
        _presentations.Count == 0 ? null : _presentations[_currentIndex];

    private int NormalizeIndex(int index)
    {
        var count = _presentations.Count;
        return ((index % count) + count) % count;
    }

    private void RaiseCurrentProperties()
    {
        OnPropertyChanged(nameof(Current));
        OnPropertyChanged(nameof(SelectedSessionIdentity));
        OnPropertyChanged(nameof(HasRunningCarousel));
        OnPropertyChanged(nameof(CounterText));
        OnPropertyChanged(nameof(AccessiblePositionText));
        OnPropertyChanged(nameof(AccessibilityDescription));
        OnPropertyChanged(nameof(InputTokenText));
        OnPropertyChanged(nameof(OutputTokenText));
        OnPropertyChanged(nameof(TotalTokenText));
        OnPropertyChanged(nameof(BubbleText));
        OnPropertyChanged(nameof(InputBubbleText));
        OnPropertyChanged(nameof(OutputBubbleText));
        OnPropertyChanged(nameof(TaskText));
        OnPropertyChanged(nameof(HasTokenBreakdown));
        OnPropertyChanged(nameof(InputFraction));
        OnPropertyChanged(nameof(OutputFraction));
        OnPropertyChanged(nameof(RemainderFraction));
    }

    private (double Input, double Output, double Remainder) TokenFractions()
    {
        decimal input = Math.Max(0, Current.InputTokens ?? 0);
        decimal output = Math.Max(0, Current.OutputTokens ?? 0);
        var known = input + output;
        decimal reportedTotal = Math.Max(0, Current.TotalTokens ?? 0);
        var denominator = Math.Max(1, Math.Max(known, reportedTotal));
        var inputFraction = (double)(input / denominator);
        var outputFraction = (double)(output / denominator);
        return (
            inputFraction,
            outputFraction,
            Math.Max(0, 1 - inputFraction - outputFraction));
    }

    private static string FormatTokens(long value) =>
        value switch
        {
            >= 1_000_000 => $"{value / 1_000_000d:0.#}M",
            >= 1_000 => $"{value / 1_000d:0.#}K",
            _ => value.ToString("N0", CultureInfo.CurrentCulture)
        };

    private static string CompactPreview(string value, int maximumLength = 160)
    {
        var normalized = string.Join(
            " ",
            value.Split(
                [' ', '\t', '\r', '\n'],
                StringSplitOptions.RemoveEmptyEntries));
        return normalized.Length <= maximumLength
            ? normalized
            : $"{normalized[..(maximumLength - 1)]}…";
    }
}
