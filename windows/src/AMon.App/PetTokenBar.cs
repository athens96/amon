using System.Windows;
using System.Windows.Media;

namespace AMon.App;

public sealed class PetTokenBar : FrameworkElement
{
    public static readonly DependencyProperty InputFractionProperty =
        DependencyProperty.Register(
            nameof(InputFraction),
            typeof(double),
            typeof(PetTokenBar),
            new FrameworkPropertyMetadata(0d, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty OutputFractionProperty =
        DependencyProperty.Register(
            nameof(OutputFraction),
            typeof(double),
            typeof(PetTokenBar),
            new FrameworkPropertyMetadata(0d, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty RemainderFractionProperty =
        DependencyProperty.Register(
            nameof(RemainderFraction),
            typeof(double),
            typeof(PetTokenBar),
            new FrameworkPropertyMetadata(1d, FrameworkPropertyMetadataOptions.AffectsRender));

    public double InputFraction
    {
        get => (double)GetValue(InputFractionProperty);
        set => SetValue(InputFractionProperty, value);
    }

    public double OutputFraction
    {
        get => (double)GetValue(OutputFractionProperty);
        set => SetValue(OutputFractionProperty, value);
    }

    public double RemainderFraction
    {
        get => (double)GetValue(RemainderFractionProperty);
        set => SetValue(RemainderFractionProperty, value);
    }

    protected override System.Windows.Size MeasureOverride(System.Windows.Size availableSize) =>
        new(double.IsInfinity(availableSize.Width) ? 150 : availableSize.Width, 5);

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        var width = Math.Max(0, ActualWidth);
        var height = Math.Max(0, ActualHeight);
        drawingContext.DrawRoundedRectangle(
            new SolidColorBrush(System.Windows.Media.Color.FromRgb(57, 60, 73)),
            null,
            new Rect(0, 0, width, height),
            height / 2,
            height / 2);

        var input = Clamp(InputFraction);
        var output = Clamp(OutputFraction);
        var remainder = Clamp(RemainderFraction);
        var total = input + output + remainder;
        if (total <= 0)
            return;

        var x = 0d;
        DrawSegment(
            drawingContext,
            ref x,
            width * input / total,
            height,
            System.Windows.Media.Color.FromRgb(124, 107, 255));
        DrawSegment(
            drawingContext,
            ref x,
            width * output / total,
            height,
            System.Windows.Media.Color.FromRgb(75, 203, 155));
    }

    private static void DrawSegment(
        DrawingContext context,
        ref double x,
        double width,
        double height,
        System.Windows.Media.Color color)
    {
        if (width <= 0)
            return;
        context.DrawRectangle(new SolidColorBrush(color), null, new Rect(x, 0, width, height));
        x += width;
    }

    private static double Clamp(double value) =>
        double.IsFinite(value) ? Math.Clamp(value, 0, 1) : 0;
}
