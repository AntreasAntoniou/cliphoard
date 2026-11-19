using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private readonly SearchInputState searchInput = new();
    private readonly DispatcherTimer searchDelay = new() { Interval = TimeSpan.FromMilliseconds(450) };
    private TimeScope? customTime;
    private string ActiveQuery => TimeQuery.Parse(searchInput.Submitted).Text;

    private void InitializeSearchInput()
    {
        searchDelay.Tick += (_, _) => { searchDelay.Stop(); if (searchInput.Composing) searchDelay.Start(); else SubmitSearch(); };
        search.TextCompositionStarted += (_, _) => { searchInput.Composing = true; searchDelay.Stop(); };
        search.TextCompositionEnded += (_, _) => { searchInput.Composing = false; SearchDraftChanged(); };
    }

    private void SearchDraftChanged()
    {
        if (!string.IsNullOrWhiteSpace(search.Text)) ClearReferenceImage();
        ++epoch; searchInput.Edit(search.Text); searchDelay.Stop();
        if (searchInput.Composing) return;
        if (string.IsNullOrWhiteSpace(search.Text) || store.State.SearchTiming == "instant") SubmitSearch();
        else
        {
            if (store.State.SearchTiming != "enter") searchDelay.Start();
            Refresh();
        }
    }

    private bool SubmitSearch()
    {
        if (!searchInput.Submit()) return false;
        searchDelay.Stop(); selected = -1;
        Refresh(); scroller.ChangeView(0, 0, null, true);
        return true;
    }

    private async Task ChooseTimeRangeAsync()
    {
        ++epoch;
        var from = new CalendarDatePicker { Header = "From", Date = customTime?.Start is DateTime start ? new DateTimeOffset(start) : DateTimeOffset.Now.AddDays(-7) };
        var to = new CalendarDatePicker { Header = "Through", Date = customTime?.End is DateTime end ? new DateTimeOffset(end) : DateTimeOffset.Now };
        var fields = new StackPanel { Spacing = 12 };
        fields.Children.Add(from); fields.Children.Add(to);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.RequestedTheme, Title = "Copied date range", Content = fields, PrimaryButtonText = "Apply", CloseButtonText = "Cancel" };
        bool wasHandingOff = handingOff; handingOff = true;
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || locked || closing || from.Date is null || to.Date is null) return;
            customTime = new("Custom range", from.Date.Value.LocalDateTime.Date, to.Date.Value.LocalDateTime.Date);
            timeFilter = "Custom range"; selected = -1; ++epoch; BuildChrome(); Refresh();
        }
        finally { handingOff = wasHandingOff; }
    }
}
