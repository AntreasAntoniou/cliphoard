using System.Security.AccessControl;
using System.Security.Principal;
namespace Cliphoard.Windows;
internal static class PrivateDirectory
{
    internal static string Create(string prefix)
    {
        string parent = Path.GetTempPath(); VerifiedModelAssets.CheckPath(parent);
        string path = Path.Combine(parent, prefix + "-" + Guid.NewGuid().ToString("N"));
        SecurityIdentifier owner = WindowsIdentity.GetCurrent().User ?? throw new IOException("Current user identity is unavailable.");
        var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false); security.SetOwner(owner);
        foreach (SecurityIdentifier sid in new[] { owner, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            security.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        FileSystemAclExtensions.Create(new DirectoryInfo(path), security); return path;
    }
}
