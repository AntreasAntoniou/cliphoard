namespace Cliphoard.Windows;
internal sealed record ManagerImportRequest(string Source, string Path);
internal sealed record ManagerImportItem(string Kind, string Text, string Source, double Created, byte[]? Image = null);
internal sealed record ManagerImportResponse(bool Success, ManagerImportItem[] Items, int Skipped, string[]? Tables = null);
