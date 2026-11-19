using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Cliphoard.Windows;

/// Retained directory lease, owner-only ACLs, regular single-link files and bounded I/O.
internal sealed class AgentWriteDirectory : IDisposable
{
    internal string Path { get; }
    private readonly SafeFileHandle anchor;
    private readonly string owner;
    private readonly FileIdentity identity;
    private bool disposed;
    private static readonly string SystemSid = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null).Value;
    internal static AgentWriteDirectory Create(string parent)
    {
        parent = System.IO.Path.GetFullPath(parent);
        if (parent.Length < 3 || parent[1] != ':' || new DriveInfo(System.IO.Path.GetPathRoot(parent)!).DriveType == DriveType.Network) throw new IOException("Choose a local agent parent folder.");
        VerifiedModelAssets.CheckPath(parent);
        string path = System.IO.Path.Combine(parent, "Cliphoard-Agent-" + Guid.NewGuid().ToString("D"));
        if (!CreateDirectory(path, 0)) throw new IOException("Could not create a private agent folder.");
        try { return new(path, initialize: true); }
        catch { try { Directory.Delete(path, false); } catch (IOException) { } catch (UnauthorizedAccessException) { } throw; }
    }
    internal AgentWriteDirectory(string path) : this(path, false) { }
    private AgentWriteDirectory(string path, bool initialize)
    {
        using var ownerIdentity = WindowsIdentity.GetCurrent(); owner = ownerIdentity.User?.Value ?? throw new IOException("Agent owner is unavailable.");
        Path = System.IO.Path.GetFullPath(path).TrimEnd('\\');
        if (Path.Length < 3 || Path[1] != ':' || new DriveInfo(System.IO.Path.GetPathRoot(Path)!).DriveType == DriveType.Network) throw new IOException("Agent folder must be local.");
        VerifiedModelAssets.CheckPath(Path);
        anchor = CreateFile(Path, initialize ? 0xe00a1u : 0x200a1u, 3, 0, 3, 0x02200000, 0);
        try
        {
            if (anchor.IsInvalid || !GetFileInformationByHandle(anchor, out identity) || (identity.Attributes & 0x410) != 0x10 || FinalPath(anchor) != Path.ToUpperInvariant()) throw new IOException("Unsafe agent folder.");
            if (initialize)
            {
                var security = new DirectorySecurity(); security.SetOwner(new SecurityIdentifier(owner)); security.SetAccessRuleProtection(true, false);
                foreach (string sid in new[] { owner, SystemSid }) security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                if (!SetKernelObjectSecurity(anchor, 5, security.GetSecurityDescriptorBinaryForm())) throw new IOException("Could not secure the new agent folder.");
            }
            ValidateSecurity(anchor); ValidateAnchor();
        }
        catch { anchor.Dispose(); throw; }
    }
    private void ValidateAnchor()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        VerifiedModelAssets.CheckPath(Path);
        if (!GetFileInformationByHandle(anchor, out FileIdentity current) || current.Volume != identity.Volume || current.IndexHigh != identity.IndexHigh || current.IndexLow != identity.IndexLow || (current.Attributes & 0x410) != 0x10 || FinalPath(anchor) != Path.ToUpperInvariant()) throw new IOException("Agent folder identity changed.");
        ValidateSecurity(anchor);
    }
    private void ValidateSecurity(SafeFileHandle handle)
    {
        uint error = GetSecurityInfo(handle, 1, 5, out _, out _, out _, out _, out nint descriptor);
        if (error != 0 || descriptor == 0) throw new IOException("Agent access controls are unavailable.");
        try
        {
            uint size = GetSecurityDescriptorLength(descriptor);
            if (size is < 20 or > 65536) throw new IOException("Invalid agent access controls.");
            byte[] bytes = new byte[size]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            var security = new RawSecurityDescriptor(bytes, 0);
            if (security.Owner?.Value != owner || security.DiscretionaryAcl is null) throw new IOException("Agent folder must belong to this account.");
            foreach (GenericAce ace in security.DiscretionaryAcl)
                if (ace is QualifiedAce { AceQualifier: AceQualifier.AccessAllowed } && (ace is not KnownAce known || known.SecurityIdentifier.Value != owner && known.SecurityIdentifier.Value != SystemSid)) throw new IOException("Agent files must be private to this account.");
        }
        finally { LocalFree(descriptor); }
    }
    private static bool ValidName(string name)
    {
        if (name == "session.json") return true;
        foreach (string suffix in new[] { ".request", ".reply" })
            if (name.EndsWith(suffix, StringComparison.Ordinal) && Guid.TryParseExact(name[..^suffix.Length], "D", out Guid id) && name[..^suffix.Length] == id.ToString("D")) return true;
        return false;
    }
    private string FilePath(string name)
    {
        if (!ValidName(name)) throw new IOException("Invalid agent file name.");
        ValidateAnchor(); return System.IO.Path.Combine(Path, name);
    }
    internal byte[]? Read(string name, int maximum)
    {
        if (maximum is < 1 or > AgentWriteProtocol.MaximumWireBytes) throw new IOException("Invalid agent read bound.");
        string path = FilePath(name);
        FileStream input;
        try { input = new FileStream(AgentDirectoryNative.Open(anchor, name, FileAccess.Read), FileAccess.Read); }
        catch (FileNotFoundException) { return null; }
        using (input)
        {
            if (!GetFileInformationByHandle(input.SafeFileHandle, out FileIdentity before) || (before.Attributes & 0x410) != 0 || before.Links != 1 || before.Volume != identity.Volume || FinalPath(input.SafeFileHandle) != path.ToUpperInvariant() || input.Length > maximum) throw new IOException("Unsafe agent file.");
            ValidateSecurity(input.SafeFileHandle);
            byte[] bytes = new byte[checked((int)input.Length)]; input.ReadExactly(bytes);
            if (!GetFileInformationByHandle(input.SafeFileHandle, out FileIdentity after) || (before with { AccessLow = after.AccessLow, AccessHigh = after.AccessHigh }) != after || input.Length != bytes.Length) throw new IOException("Agent file changed during reading.");
            ValidateAnchor(); ValidateSecurity(input.SafeFileHandle); return bytes;
        }
    }
    internal void WriteExclusive(string name, byte[] bytes)
    {
        if (bytes.Length > AgentWriteProtocol.MaximumWireBytes) throw new IOException("Agent frame exceeds its bound.");
        _ = FilePath(name);
        string temporaryName = ".agent-" + Guid.NewGuid().ToString("N") + ".tmp";
        string temporary = System.IO.Path.Combine(Path, temporaryName);
        using var handle = AgentDirectoryNative.Open(anchor, temporaryName, FileAccess.Write, create: true);
        bool published = false;
        using var output = new FileStream(handle, FileAccess.Write);
        try
        {
            if (FinalPath(output.SafeFileHandle) != temporary.ToUpperInvariant()) throw new IOException("Agent file identity changed.");
            ValidateSecurity(output.SafeFileHandle); output.Write(bytes); output.Flush(true);
            ValidateAnchor(); AgentDirectoryNative.RenameExclusive(output.SafeFileHandle, anchor, name); published = true; ValidateAnchor();
        }
        finally { if (!published && !handle.IsClosed) AgentDirectoryNative.Delete(handle); }
    }
    internal void Remove(string name)
    {
        _ = FilePath(name);
        try { using var handle = AgentDirectoryNative.Open(anchor, name, FileAccess.Read, delete: true); AgentDirectoryNative.Delete(handle); }
        catch (FileNotFoundException) { }
        ValidateAnchor();
    }
    internal string[] RequestNames()
    {
        ValidateAnchor(); string[] entries = Directory.EnumerateFileSystemEntries(Path).Take(257).ToArray();
        if (entries.Length > 256) throw new IOException("Agent folder exceeds its scan bound.");
        string[] names = entries.Select(System.IO.Path.GetFileName).Where(name => name is not null && name.EndsWith(".request", StringComparison.Ordinal)).Cast<string>().ToArray();
        if (names.Length > 64 || names.Any(name => !ValidName(name))) throw new IOException("Agent inbox exceeds its request bound.");
        ValidateAnchor(); return names.Order(StringComparer.Ordinal).ToArray();
    }
    private static string FinalPath(SafeFileHandle handle)
    {
        var text = new StringBuilder(32768); uint length = GetFinalPathNameByHandle(handle, text, (uint)text.Capacity, 0);
        if (length == 0 || length >= text.Capacity || !text.ToString().StartsWith("\\\\?\\", StringComparison.Ordinal)) throw new IOException("Agent file identity is unavailable.");
        return text.ToString()[4..].ToUpperInvariant();
    }
    public void Dispose() { disposed = true; anchor.Dispose(); }
    [StructLayout(LayoutKind.Sequential)] private readonly record struct FileIdentity(uint Attributes, uint CreationLow, uint CreationHigh, uint AccessLow, uint AccessHigh, uint WriteLow, uint WriteHigh, uint Volume, uint SizeHigh, uint SizeLow, uint Links, uint IndexHigh, uint IndexLow);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateDirectory(string path, nint security);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFile(string path, uint access, uint share, nint security, uint creation, uint flags, nint template);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileIdentity info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint count, uint flags);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetKernelObjectSecurity(SafeFileHandle handle, uint information, byte[] descriptor);
    [DllImport("advapi32.dll")] private static extern uint GetSecurityInfo(SafeFileHandle handle, uint type, uint information, out nint owner, out nint group, out nint dacl, out nint sacl, out nint descriptor);
    [DllImport("advapi32.dll")] private static extern uint GetSecurityDescriptorLength(nint descriptor);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint memory);
}
