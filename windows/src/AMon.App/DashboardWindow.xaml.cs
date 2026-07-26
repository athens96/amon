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
    }

    public PetViewModel? PetViewModel
    {
        get => (PetViewModel?)GetValue(PetViewModelProperty);
        set => SetValue(PetViewModelProperty, value);
    }
}
