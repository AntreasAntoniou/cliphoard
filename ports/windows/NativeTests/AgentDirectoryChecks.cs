using Cliphoard.Windows;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
internal static class AgentDirectoryChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Agent directory check {checks} failed"); }
        void Refuses(Action action) { try { action(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Check(true); return; } Check(false); }
        string parent = Path.Combine(Path.GetTempPath(), "CliphoardAgentFolderFixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(parent);
        try
        {
            using var folder = AgentWriteDirectory.Create(parent);
            Check(new DirectoryInfo(folder.Path).GetAccessControl().AreAccessRulesProtected);
            string request = Guid.NewGuid().ToString("D") + ".request", other = Guid.NewGuid().ToString("D") + ".request";
            byte[] marker = Encoding.UTF8.GetBytes("synthetic transport marker");
            Check(folder.Read(request, 65536) is null);
            folder.WriteExclusive(request, marker); Check(folder.Read(request, 65536)!.SequenceEqual(marker));
            Check(folder.RequestNames().SequenceEqual(new[] { request }));
            Refuses(() => folder.WriteExclusive(request, marker));
            Check(folder.Read(request, 65536)!.SequenceEqual(marker));
            Refuses(() => folder.Read(request, marker.Length - 1));
            Refuses(() => folder.Read("..\\escape.request", 65536));
            Refuses(() => folder.WriteExclusive(other, new byte[65537]));
            Refuses(() => Directory.Move(folder.Path, folder.Path + "-moved"));
            Check(CreateHardLink(Path.Combine(folder.Path, other), Path.Combine(folder.Path, request), 0));
            Refuses(() => folder.Read(request, 65536));
            folder.Remove(other); Check(folder.Read(request, 65536)!.SequenceEqual(marker));
            var broader = new DirectoryInfo(folder.Path).GetAccessControl();
            var worldRead = new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read, AccessControlType.Allow); broader.AddAccessRule(worldRead);
            try { new DirectoryInfo(folder.Path).SetAccessControl(broader); Refuses(() => folder.Read(request, 65536)); }
            finally { broader.RemoveAccessRuleSpecific(worldRead); new DirectoryInfo(folder.Path).SetAccessControl(broader); }
            folder.Remove(request); Check(folder.RequestNames().Length == 0);
            Check(Directory.GetFiles(folder.Path, "*.tmp").Length == 0);
            string outside = Path.Combine(parent, "synthetic-outside"); Directory.CreateDirectory(outside);
            string outsideFile = Path.Combine(outside, "synthetic.txt"); File.WriteAllText(outsideFile, "synthetic outside marker");
            string junctionName = Guid.NewGuid().ToString("D") + ".request";
            using (var junction = new SyntheticJunction(Path.Combine(folder.Path, junctionName), outside))
            {
                Refuses(() => folder.Read(junctionName, 65536));
                Refuses(() => folder.WriteExclusive(junctionName, marker));
                Check(File.ReadAllText(outsideFile) == "synthetic outside marker" && Directory.GetFiles(outside).Length == 1);
            }
            string nestedParent = Path.Combine(parent, "synthetic-parent"); Directory.CreateDirectory(nestedParent);
            using (var anchored = AgentWriteDirectory.Create(nestedParent))
            {
                string moved = nestedParent + "-moved"; bool renamed = false;
                try { Directory.Move(nestedParent, moved); renamed = true; }
                catch (IOException) { Check(true); }
                if (renamed)
                {
                    Directory.CreateDirectory(nestedParent);
                    string replacement = Path.Combine(nestedParent, Path.GetFileName(anchored.Path)); Directory.CreateDirectory(replacement);
                    Refuses(() => anchored.WriteExclusive(Guid.NewGuid().ToString("D") + ".request", marker));
                    Check(Directory.GetFiles(replacement).Length == 0);
                }
            }
        }
        finally { Directory.Delete(parent, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { agent_directory_checks = checks, status = "passed", generated_data_only = true }));
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateHardLink(string file, string existing, nint security);
}
