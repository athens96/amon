using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AMon.Activity;

namespace AMon.App;

public sealed class CodexPetSpriteControl : FrameworkElement
{
    public static readonly DependencyProperty SourcePathProperty =
        DependencyProperty.Register(
            nameof(SourcePath),
            typeof(string),
            typeof(CodexPetSpriteControl),
            new FrameworkPropertyMetadata(string.Empty, OnSourcePathChanged));

    public static readonly DependencyProperty StatusProperty =
        DependencyProperty.Register(
            nameof(Status),
            typeof(PetActivityStatus),
            typeof(CodexPetSpriteControl),
            new FrameworkPropertyMetadata(
                PetActivityStatus.Idle,
                FrameworkPropertyMetadataOptions.AffectsRender,
                OnStatusChanged));

    public static readonly DependencyProperty SpriteVersionProperty =
        DependencyProperty.Register(
            nameof(SpriteVersion),
            typeof(int),
            typeof(CodexPetSpriteControl),
            new FrameworkPropertyMetadata(1, OnSpriteVersionChanged));

    public static readonly DependencyProperty SpriteRevisionProperty =
        DependencyProperty.Register(
            nameof(SpriteRevision),
            typeof(int),
            typeof(CodexPetSpriteControl),
            new FrameworkPropertyMetadata(0, OnSpriteRevisionChanged));

    public static readonly DependencyProperty DragDirectionProperty =
        DependencyProperty.Register(
            nameof(DragDirection),
            typeof(int),
            typeof(CodexPetSpriteControl),
            new FrameworkPropertyMetadata(
                0,
                FrameworkPropertyMetadataOptions.AffectsRender));

    private readonly DispatcherTimer _timer;
    private readonly Stopwatch _elapsed = new();
    private readonly Dictionary<CodexPetAnimation, IReadOnlyList<BitmapSource>> _frames = [];
    private bool _playsReadyTransition;

    public CodexPetSpriteControl()
    {
        _timer = new DispatcherTimer(
            TimeSpan.FromMilliseconds(1000d / 15d),
            DispatcherPriority.Render,
            (_, _) => InvalidateVisual(),
            Dispatcher);
        Loaded += (_, _) => Start();
        Unloaded += (_, _) => Stop();
    }

    public string SourcePath
    {
        get => (string)GetValue(SourcePathProperty);
        set => SetValue(SourcePathProperty, value);
    }

    public PetActivityStatus Status
    {
        get => (PetActivityStatus)GetValue(StatusProperty);
        set => SetValue(StatusProperty, value);
    }

    public int SpriteVersion
    {
        get => (int)GetValue(SpriteVersionProperty);
        set => SetValue(SpriteVersionProperty, value);
    }

    public int SpriteRevision
    {
        get => (int)GetValue(SpriteRevisionProperty);
        set => SetValue(SpriteRevisionProperty, value);
    }

    public int DragDirection
    {
        get => (int)GetValue(DragDirectionProperty);
        set => SetValue(DragDirectionProperty, value);
    }

    protected override System.Windows.Size MeasureOverride(
        System.Windows.Size availableSize) =>
        new(
            double.IsInfinity(availableSize.Width) ? 126 : availableSize.Width,
            double.IsInfinity(availableSize.Height) ? 148 : availableSize.Height);

    protected override void OnMouseEnter(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        InvalidateVisual();
    }

    protected override void OnMouseLeave(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        InvalidateVisual();
    }

    protected override void OnMouseMove(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (Status == PetActivityStatus.Idle
            && CodexPetSpriteLayout.NormalizeVersion(SpriteVersion) >= 2)
            InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        var gazeDirection = 0;
        if (Status == PetActivityStatus.Idle
            && CodexPetSpriteLayout.NormalizeVersion(SpriteVersion) >= 2
            && IsMouseOver)
        {
            gazeDirection =
                System.Windows.Input.Mouse.GetPosition(this).X >= ActualWidth / 2
                    ? 1
                    : -1;
        }
        var reduceMotion = !SystemParameters.ClientAreaAnimation;
        var animation = CodexPetSpriteLayout.AnimationFor(
            Status,
            SpriteVersion,
            gazeDirection,
            DragDirection,
            _playsReadyTransition ? _elapsed.Elapsed : null,
            reduceMotion);
        if (!_frames.TryGetValue(animation, out var frames) || frames.Count == 0)
            return;
        var index = CodexPetSpriteLayout.FrameIndex(
            CodexPetSpriteLayout.PlaybackElapsedFor(
                Status,
                SpriteVersion,
                _elapsed.Elapsed,
                reduceMotion),
            animation,
            reduceMotion);
        var frame = frames[Math.Clamp(index, 0, frames.Count - 1)];
        var scale = Math.Min(
            ActualWidth / frame.PixelWidth,
            ActualHeight / frame.PixelHeight);
        var width = frame.PixelWidth * scale;
        var height = frame.PixelHeight * scale;
        drawingContext.DrawImage(
            frame,
            new Rect(
                (ActualWidth - width) / 2,
                ActualHeight - height,
                width,
                height));
    }

    private void LoadFrames()
    {
        _frames.Clear();
        if (!CodexPetAssetService.IsValidSprite(SourcePath, SpriteVersion))
        {
            InvalidateVisual();
            return;
        }
        try
        {
            var sheet = CodexPetAssetService.LoadBitmapSource(SourcePath);
            foreach (var (animation, strip) in CodexPetSpriteLayout.Strips)
            {
                if (strip.Row >= CodexPetSpriteLayout.RowCountFor(SpriteVersion))
                    continue;
                var frames = new List<BitmapSource>(strip.FrameCount);
                for (var column = 0; column < strip.FrameCount; column++)
                {
                    var frame = new CroppedBitmap(
                        sheet,
                        new Int32Rect(
                            column * CodexPetSpriteLayout.FramePixelWidth,
                            strip.Row * CodexPetSpriteLayout.FramePixelHeight,
                            CodexPetSpriteLayout.FramePixelWidth,
                            CodexPetSpriteLayout.FramePixelHeight));
                    frame.Freeze();
                    frames.Add(frame);
                }
                _frames[animation] = frames;
            }
        }
        catch (Exception exception) when (
            exception is IOException
                or InvalidOperationException
                or NotSupportedException)
        {
            _frames.Clear();
        }
        _elapsed.Restart();
        InvalidateVisual();
    }

    private void Start()
    {
        if (_frames.Count == 0)
            LoadFrames();
        _elapsed.Start();
        if (SystemParameters.ClientAreaAnimation)
            _timer.Start();
    }

    private void Stop()
    {
        _timer.Stop();
        _elapsed.Stop();
    }

    private static void OnSourcePathChanged(
        DependencyObject dependencyObject,
        DependencyPropertyChangedEventArgs e) =>
        ((CodexPetSpriteControl)dependencyObject).LoadFrames();

    private static void OnSpriteVersionChanged(
        DependencyObject dependencyObject,
        DependencyPropertyChangedEventArgs e)
    {
        var control = (CodexPetSpriteControl)dependencyObject;
        var normalized = CodexPetSpriteLayout.NormalizeVersion((int)e.NewValue);
        if ((int)e.NewValue != normalized)
        {
            control.SetCurrentValue(SpriteVersionProperty, normalized);
            return;
        }
        control.LoadFrames();
    }

    private static void OnSpriteRevisionChanged(
        DependencyObject dependencyObject,
        DependencyPropertyChangedEventArgs e) =>
        ((CodexPetSpriteControl)dependencyObject).LoadFrames();

    private static void OnStatusChanged(
        DependencyObject dependencyObject,
        DependencyPropertyChangedEventArgs e)
    {
        var control = (CodexPetSpriteControl)dependencyObject;
        control._playsReadyTransition =
            e.NewValue is PetActivityStatus.Ready
            && e.OldValue is not PetActivityStatus.Ready;
        control._elapsed.Restart();
        control.InvalidateVisual();
    }
}
