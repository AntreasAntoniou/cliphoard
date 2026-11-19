using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Cliphoard.Windows;

/// Relative NT file operations keep every transport entry anchored to the retained directory.
internal static class AgentDirectoryNative
{
    internal static SafeFileHandle Open(SafeFileHandle root, string name, FileAccess access, bool create = false, bool delete = false)
    {
        ValidateLeaf(name);
        nint text = Marshal.StringToHGlobalUni(name), unicode = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
        bool retained = false;
        try
        {
            root.DangerousAddRef(ref retained);
            Marshal.StructureToPtr(new UnicodeString { Length = checked((ushort)(name.Length * 2)), MaximumLength = checked((ushort)(name.Length * 2 + 2)), Buffer = text }, unicode, false);
            var attributes = new ObjectAttributes { Length = (uint)Marshal.SizeOf<ObjectAttributes>(), Root = root.DangerousGetHandle(), Name = unicode, Attributes = 0x40 }; // One literal leaf. FILE_OPEN_REPARSE_POINT returns links for rejection.
            // Explicit FILE_GENERIC rights include SYNCHRONIZE before synchronous-open validation.
            uint desired = access == FileAccess.Read ? 0x120089u : 0x120116u;
            if (create || delete) desired |= 0x10000; // DELETE also admits atomic publication and cleanup.
            int status = NtCreateFile(out SafeFileHandle handle, desired, ref attributes, out _, 0, 0x80, create ? 0u : delete ? 7u : 1u, create ? 2u : 1u, 0x200060, 0, 0);
            if (status >= 0) return handle;
            handle.Dispose(); Throw(status); throw new IOException();
        }
        finally { if (retained) root.DangerousRelease(); Marshal.FreeHGlobal(unicode); Marshal.FreeHGlobal(text); }
    }
    internal static void RenameExclusive(SafeFileHandle file, SafeFileHandle root, string name)
    {
        ValidateLeaf(name);
        byte[] filename = Encoding.Unicode.GetBytes(name);
        int rootOffset = nint.Size, lengthOffset = rootOffset + nint.Size, nameOffset = lengthOffset + 4;
        int size = nameOffset + filename.Length; nint buffer = Marshal.AllocHGlobal(size); bool retained = false;
        try
        {
            root.DangerousAddRef(ref retained);
            Marshal.Copy(new byte[size], 0, buffer, size); // ReplaceIfExists remains false.
            Marshal.WriteIntPtr(buffer, rootOffset, root.DangerousGetHandle()); Marshal.WriteInt32(buffer, lengthOffset, filename.Length); Marshal.Copy(filename, 0, buffer + nameOffset, filename.Length);
            int status = NtSetInformationFile(file, out _, buffer, (uint)size, 10);
            if (status < 0) Throw(status);
        }
        finally { if (retained) root.DangerousRelease(); Marshal.FreeHGlobal(buffer); }
    }
    internal static void Delete(SafeFileHandle file)
    {
        nint buffer = Marshal.AllocHGlobal(1);
        try { Marshal.WriteByte(buffer, 1); int status = NtSetInformationFile(file, out _, buffer, 1, 13); if (status < 0) Throw(status); }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static void ValidateLeaf(string name)
    {
        if (name.Length is < 1 or > 128 || name is "." or ".." || name.IndexOfAny(new[] { '\\', '/', ':', '\0' }) >= 0) throw new IOException("Invalid relative agent entry.");
    }
    private static void Throw(int status)
    {
        uint error = RtlNtStatusToDosError(status);
        if (error is 2 or 3) throw new FileNotFoundException("Agent entry is unavailable.");
        throw new IOException($"Private agent file operation failed ({error}, NTSTATUS {unchecked((uint)status):X8}).");
    }
    [StructLayout(LayoutKind.Sequential)] private struct UnicodeString { internal ushort Length, MaximumLength; internal nint Buffer; }
    [StructLayout(LayoutKind.Sequential)] private struct ObjectAttributes { internal uint Length; internal nint Root, Name; internal uint Attributes; internal nint Security, Quality; }
    [StructLayout(LayoutKind.Sequential)] private struct IoStatus { internal nint Status; internal nuint Information; }
    [DllImport("ntdll.dll")] private static extern int NtCreateFile(out SafeFileHandle file, uint access, ref ObjectAttributes attributes, out IoStatus result, nint allocation, uint fileAttributes, uint share, uint disposition, uint options, nint extendedAttributes, uint extendedLength);
    [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(SafeFileHandle file, out IoStatus result, nint information, uint length, uint informationClass);
    [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
}
