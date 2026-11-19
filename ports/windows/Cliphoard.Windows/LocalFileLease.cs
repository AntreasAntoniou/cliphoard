using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Text;
namespace Cliphoard.Windows;

/// Retains a stable local file identity and denies replacement or concurrent writes.
internal static class LocalFileLease
{
    internal static string Identity(FileStream file)
    {
        if (!GetFileInformationByHandle(file.SafeFileHandle, out FileInformation information)) throw new IOException("File identity is unavailable.");
        return information.Volume.ToString("X8") + information.IndexHigh.ToString("X8") + information.IndexLow.ToString("X8");
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Modified;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);
    internal static FileStream Open(string path, long maximum)
    {
        if (!Path.IsPathFullyQualified(path) || path.Length < 3 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\' || new DriveInfo(Path.GetPathRoot(path)!).DriveType == DriveType.Network) throw new IOException("Choose a supported local file.");
        path = Path.GetFullPath(path); VerifiedModelAssets.CheckPath(path);
        var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous);
        try
        {
            var final = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(file.SafeFileHandle, final, (uint)final.Capacity, 0);
            if (length == 0 || length >= final.Capacity || !final.ToString().Equals("\\\\?\\" + path, StringComparison.OrdinalIgnoreCase) || file.Length > maximum) throw new IOException("File identity or size is unavailable.");
            return file;
        }
        catch { file.Dispose(); throw; }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint capacity, uint flags);
}
