using Microsoft.UI.Xaml.Controls;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private int activePreparations;
    private Button? cancelPreparationButton;
    private async Task<bool> RunPreparationAsync(Func<Task<bool>> prepare)
    {
        ++activePreparations; if (cancelPreparationButton is not null) cancelPreparationButton.IsEnabled = true;
        try { return await prepare(); }
        finally { --activePreparations; if (cancelPreparationButton is not null) cancelPreparationButton.IsEnabled = activePreparations != 0; }
    }
    private void AddPreparationCancellation(StackPanel body)
    {
        cancelPreparationButton = new Button { Content = "Cancel model preparation", IsEnabled = activePreparations != 0 };
        cancelPreparationButton.Click += (_, _) => { if (activePreparations != 0) cancelPreparation(); };
        body.Children.Add(cancelPreparationButton);
    }
}
