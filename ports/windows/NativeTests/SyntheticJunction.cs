using Microsoft.Win32.SafeHandles;
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text;
internal sealed class SyntheticJunction : IDisposable
{
    private readonly string path;
    internal SyntheticJunction(string path, string target)
    {
        this.path = path; Directory.CreateDirectory(path);
        try
        {
            byte[] substitute = Encoding.Unicode.GetBytes(@"\??\" + Path.GetFullPath(target)), print = Encoding.Unicode.GetBytes(Path.GetFullPath(target));
            byte[] buffer = new byte[20 + substitute.Length + print.Length];
            BinaryPrimitives.WriteUInt32LittleEndian(buffer, 0xA0000003); BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(4), checked((ushort)(buffer.Length - 8)));
            BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(10), checked((ushort)substitute.Length)); BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(12), checked((ushort)(substitute.Length + 2))); BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(14), checked((ushort)print.Length));
            substitute.CopyTo(buffer, 16); print.CopyTo(buffer, 18 + substitute.Length);
            using SafeFileHandle handle = CreateFile(path, 0x40000000, 7, 0, 3, 0x02200000, 0);
            if (handle.IsInvalid || !DeviceIoControl(handle, 0x900A4, buffer, buffer.Length, 0, 0, out _, 0)) throw new IOException("Synthetic junction could not be created.", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
        }
        catch { Directory.Delete(path); throw; }
    }
    public void Dispose() { if (Directory.Exists(path)) Directory.Delete(path); }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFile(string name, uint access, uint share, nint security, uint creation, uint flags, nint template);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeviceIoControl(SafeFileHandle file, uint code, byte[] input, int inputSize, nint output, int outputSize, out uint returned, nint overlapped);
}
