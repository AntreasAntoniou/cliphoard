namespace Cliphoard.Windows;

internal sealed class SearchInputState
{
    internal string Draft { get; private set; } = "";
    internal string Submitted { get; private set; } = "";
    internal bool Composing { get; set; }
    internal bool Pending => Draft != Submitted;
    internal void Edit(string value) => Draft = value;
    internal void Reset(string value) { Draft = value; Submitted = value; Composing = false; }
    internal bool Submit()
    {
        if (!Pending || Composing) return false;
        Submitted = Draft;
        return true;
    }
}
