using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Navigation;
using AMon.Core.Markdown;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using FontFamily = System.Windows.Media.FontFamily;
using Rectangle = System.Windows.Shapes.Rectangle;

namespace AMon.App;

/// Renders transcript Markdown as native WPF elements — the Windows counterpart of the macOS
/// `MarkdownView`. Blocks come from the shared parser; inline runs become `Run`/`Bold`/`Italic`/
/// `Hyperlink` inlines, so text stays selectable and wraps like a plain `TextBlock` did.
public sealed class MarkdownTextBlock : StackPanel
{
    public static readonly DependencyProperty MarkdownProperty = DependencyProperty.Register(
        nameof(Markdown),
        typeof(string),
        typeof(MarkdownTextBlock),
        new FrameworkPropertyMetadata(string.Empty, FrameworkPropertyMetadataOptions.AffectsMeasure, OnMarkdownChanged));

    public static readonly DependencyProperty BaseFontSizeProperty = DependencyProperty.Register(
        nameof(BaseFontSize),
        typeof(double),
        typeof(MarkdownTextBlock),
        new FrameworkPropertyMetadata(13d, FrameworkPropertyMetadataOptions.AffectsMeasure, OnMarkdownChanged));

    private static readonly FontFamily MonospaceFamily = new("Cascadia Mono, Consolas");

    public string Markdown
    {
        get => (string)GetValue(MarkdownProperty);
        set => SetValue(MarkdownProperty, value);
    }

    public double BaseFontSize
    {
        get => (double)GetValue(BaseFontSizeProperty);
        set => SetValue(BaseFontSizeProperty, value);
    }

    private static void OnMarkdownChanged(DependencyObject sender, DependencyPropertyChangedEventArgs e) =>
        ((MarkdownTextBlock)sender).Rebuild();

    private void Rebuild()
    {
        Children.Clear();
        foreach (var block in MarkdownParser.Parse(Markdown))
            Children.Add(Build(block));
    }

    private UIElement Build(MarkdownBlock block) => block switch
    {
        MarkdownHeading heading => Paragraph(heading.Content, HeadingSize(heading.Level), FontWeights.SemiBold, topMargin: 6),
        MarkdownParagraph paragraph => Paragraph(paragraph.Content, BaseFontSize, FontWeights.Normal),
        MarkdownCodeBlock code => CodeBlock(code.Code),
        MarkdownListItem item => ListItem(item),
        MarkdownQuote quote => Quote(quote.Content),
        MarkdownRule => new Rectangle { Height = 1, Margin = new Thickness(0, 6, 0, 6), Fill = Brush("LineBrush"), Opacity = 0.8 },
        MarkdownTable table => Table(table),
        _ => Paragraph(string.Empty, BaseFontSize, FontWeights.Normal),
    };

    private TextBlock Paragraph(string content, double size, FontWeight weight, double topMargin = 2, Brush? foreground = null)
    {
        var text = new TextBlock
        {
            FontSize = size,
            FontWeight = weight,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = Math.Round(size * 1.6),
            Margin = new Thickness(0, topMargin, 0, 2),
        };
        if (foreground is not null)
            text.Foreground = foreground;
        AppendInlines(text.Inlines, content);
        return text;
    }

    private void AppendInlines(InlineCollection inlines, string content)
    {
        foreach (var run in MarkdownParser.Inlines(content))
        {
            switch (run.Kind)
            {
                case MarkdownInlineKind.Bold:
                    inlines.Add(new Bold(new Run(run.Text)));
                    break;
                case MarkdownInlineKind.Italic:
                    inlines.Add(new Italic(new Run(run.Text)));
                    break;
                case MarkdownInlineKind.Strikethrough:
                    inlines.Add(new Run(run.Text) { TextDecorations = TextDecorations.Strikethrough });
                    break;
                case MarkdownInlineKind.Code:
                    inlines.Add(new Run(run.Text)
                    {
                        FontFamily = MonospaceFamily,
                        FontSize = Math.Max(10, BaseFontSize - 1),
                        Background = Brush("SurfaceStrongBrush"),
                    });
                    break;
                case MarkdownInlineKind.Link:
                    inlines.Add(Link(run));
                    break;
                default:
                    inlines.Add(new Run(run.Text));
                    break;
            }
        }
    }

    private Hyperlink Link(MarkdownInlineRun run)
    {
        var link = new Hyperlink(new Run(run.Text)) { ToolTip = run.Url };
        if (Uri.TryCreate(run.Url, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
        {
            link.NavigateUri = uri;
            link.RequestNavigate += OnRequestNavigate;
        }
        return link;
    }

    private static void OnRequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            // A missing browser association is the user's environment; the transcript stays readable.
        }
        e.Handled = true;
    }

    private Border CodeBlock(string code) => new()
    {
        Margin = new Thickness(0, 4, 0, 4),
        Padding = new Thickness(10, 8, 10, 8),
        CornerRadius = new CornerRadius(6),
        Background = Brush("SurfaceStrongBrush"),
        Child = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = new TextBlock
            {
                Text = code,
                FontFamily = MonospaceFamily,
                FontSize = Math.Max(10, BaseFontSize - 1),
                TextWrapping = TextWrapping.NoWrap,
            },
        },
    };

    private Grid ListItem(MarkdownListItem item)
    {
        var grid = new Grid { Margin = new Thickness(item.Indent * 14, 1, 0, 1) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var marker = new TextBlock
        {
            Text = item.Marker,
            FontSize = BaseFontSize,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("MutedBrush"),
            Margin = new Thickness(0, 2, 8, 0),
            MinWidth = 14,
        };
        var content = Paragraph(item.Content, BaseFontSize, FontWeights.Normal, topMargin: 0);
        Grid.SetColumn(content, 1);
        grid.Children.Add(marker);
        grid.Children.Add(content);
        return grid;
    }

    private Grid Quote(string content)
    {
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new Border { Background = Brush("AccentBrush"), Opacity = 0.5, CornerRadius = new CornerRadius(2) });
        var text = Paragraph(content, BaseFontSize, FontWeights.Normal, topMargin: 0, foreground: Brush("MutedBrush"));
        text.Margin = new Thickness(10, 0, 0, 0);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    private ScrollViewer Table(MarkdownTable table)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        for (var column = 0; column < table.Headers.Count; column++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var rowCount = table.Rows.Count + 1;
        for (var row = 0; row < rowCount; row++)
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        for (var column = 0; column < table.Headers.Count; column++)
            grid.Children.Add(Cell(table.Headers[column], 0, column, table, header: true));
        for (var row = 0; row < table.Rows.Count; row++)
        {
            for (var column = 0; column < table.Headers.Count; column++)
                grid.Children.Add(Cell(column < table.Rows[row].Count ? table.Rows[row][column] : string.Empty, row + 1, column, table, header: false));
        }
        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = grid,
        };
    }

    private Border Cell(string content, int row, int column, MarkdownTable table, bool header)
    {
        var alignment = column < table.Alignments.Count ? table.Alignments[column] : MarkdownColumnAlignment.Leading;
        var text = Paragraph(content, BaseFontSize, header ? FontWeights.SemiBold : FontWeights.Normal, topMargin: 0);
        text.TextAlignment = alignment switch
        {
            MarkdownColumnAlignment.Center => TextAlignment.Center,
            MarkdownColumnAlignment.Trailing => TextAlignment.Right,
            _ => TextAlignment.Left,
        };
        text.Margin = new Thickness(0);
        var cell = new Border
        {
            Padding = new Thickness(10, 5, 10, 5),
            BorderBrush = Brush("LineBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Background = header ? Brush("SurfaceStrongBrush") : Brushes.Transparent,
            Child = text,
        };
        Grid.SetRow(cell, row);
        Grid.SetColumn(cell, column);
        return cell;
    }

    private double HeadingSize(int level) => level switch
    {
        1 => BaseFontSize + 6,
        2 => BaseFontSize + 4,
        3 => BaseFontSize + 2,
        _ => BaseFontSize + 1,
    };

    private Brush Brush(string key) =>
        TryFindResource(key) as Brush ?? Brushes.Gray;
}
