using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using System.Drawing.Imaging;

if (args.Length is not (4 or 5) || args[1] is not ("arm64" or "x64") || !Version.TryParse(args[2], out Version? version) || version.Build < 0 || version.Revision < 0) throw new ArgumentException("Usage: Packaging <source-root> <arm64|x64> <version> <output-directory> [dotnet-path]");
string root = Path.GetFullPath(args[0]), architecture = args[1], output = Path.GetFullPath(args[3]);
string dotnet = args.Length == 5 ? args[4] : Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? (Environment.GetEnvironmentVariable("DOTNET_ROOT") is string dotnetRoot ? Path.Combine(dotnetRoot, "dotnet.exe") : "dotnet");
Directory.CreateDirectory(output);
string payload = Path.Combine(output, $"Cliphoard-{version}-{architecture}");
if (Directory.Exists(payload) || File.Exists(payload + ".msi")) throw new IOException("Choose a fresh output directory.");
string project = Path.Combine(root, @"ports\windows\Cliphoard.Windows\Cliphoard.Windows.csproj");
Run(dotnet, "publish", project, "-c", "Release", "-p:Platform=" + (architecture == "arm64" ? "ARM64" : "x64"), "-r", "win-" + architecture, "--self-contained", "true", "-p:PublishSingleFile=false", "-p:RestoreLockedMode=true", "-p:Version=" + version.ToString(3), "-p:AssemblyVersion=" + version.ToString(4), "-p:TreatWarningsAsErrors=true", "-o", payload);
if (!File.Exists(Path.Combine(payload, @"ModelWorker\Cliphoard.ModelWorker.exe"))) throw new IOException("The private model worker is missing.");
if (!File.Exists(Path.Combine(payload, @"Companion\Cliphoard.Companion.exe"))) throw new IOException("The agent companion is missing.");
File.Copy(Path.Combine(root, "LICENSE"), Path.Combine(payload, "LICENSE.txt"));
if (!File.Exists(Path.Combine(payload, "Cliphoard.Windows.pri")) || !File.Exists(Path.Combine(payload, "App.xbf"))) throw new IOException("Published WinUI resources are incomplete.");
if (Directory.GetFiles(payload, "NativeTests*", SearchOption.AllDirectories).Length != 0) throw new IOException("Test binary in release payload.");
if (Directory.EnumerateFiles(payload, "*", SearchOption.AllDirectories).Any(path =>
    Path.GetExtension(path) is ".safetensors" or ".litertlm" or ".gguf" or ".onnx" or ".mlmodel" ||
    Path.GetFileName(path).StartsWith("ggml-", StringComparison.OrdinalIgnoreCase) && Path.GetExtension(path).Equals(".bin", StringComparison.OrdinalIgnoreCase) ||
    Path.GetFileName(path) == "open_clip_pytorch_model.bin")) throw new IOException("Learned model weights in release payload.");
var hashes = Directory.EnumerateFiles(payload, "*", SearchOption.AllDirectories).OrderBy(path => path, StringComparer.Ordinal).ToDictionary(path => Path.GetRelativePath(payload, path), path => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))));
File.WriteAllText(Path.Combine(payload, "SHA256SUMS.json"), JsonSerializer.Serialize(hashes, new JsonSerializerOptions { WriteIndented = true }));
ZipFile.CreateFromDirectory(payload, payload + ".zip", CompressionLevel.Optimal, false);

// MSI is per-user and self-contained. It never modifies the encrypted history directory.
XNamespace wix = "http://wixtoolset.org/schemas/v4/wxs";
var package = new XElement(wix + "Package", new XAttribute("Name", "Cliphoard"), new XAttribute("Manufacturer", "Axiotic"), new XAttribute("Version", version.ToString(3)), new XAttribute("UpgradeCode", "FDDB1529-DB02-4473-9E58-53597BD44515"), new XAttribute("Scope", "perUser"));
package.Add(new XElement(wix + "MajorUpgrade", new XAttribute("DowngradeErrorMessage", "A newer Cliphoard version is installed."), new XAttribute("AllowSameVersionUpgrades", "yes")));
package.Add(new XElement(wix + "MediaTemplate", new XAttribute("EmbedCab", "yes")));
var install = new XElement(wix + "Directory", new XAttribute("Id", "INSTALLFOLDER"), new XAttribute("Name", "Cliphoard"));
var programs = new XElement(wix + "Directory", new XAttribute("Id", "UserPrograms"), new XAttribute("Name", "Programs"), install);
package.Add(new XElement(wix + "StandardDirectory", new XAttribute("Id", "LocalAppDataFolder"), programs));
package.Add(new XElement(wix + "StandardDirectory", new XAttribute("Id", "ProgramMenuFolder")));
package.Add(new XElement(wix + "StandardDirectory", new XAttribute("Id", "DesktopFolder")));
var feature = new XElement(wix + "Feature", new XAttribute("Id", "Main"), new XAttribute("Title", "Cliphoard"), new XAttribute("Level", "1")); package.Add(feature);
var directories = new Dictionary<string, XElement>(StringComparer.OrdinalIgnoreCase) { [""] = install };
string? appFileId = null;
foreach (string file in Directory.EnumerateFiles(payload, "*", SearchOption.AllDirectories).OrderBy(path => path, StringComparer.Ordinal))
{
    string relative = Path.GetRelativePath(payload, file), parent = Path.GetDirectoryName(relative) ?? "";
    XElement directory = GetDirectory(parent);
    string id = "Payload" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(relative))).Substring(0, 20);
    var component = new XElement(wix + "Component", new XAttribute("Id", id), new XAttribute("Guid", StableGuid(architecture + ":payload-v2:" + relative)), new XElement(wix + "File", new XAttribute("Id", id + "File"), new XAttribute("Source", file)));
    // HKCU key paths make the per-user component independent of other users' installations.
    component.Add(new XElement(wix + "RegistryValue", new XAttribute("Root", "HKCU"), new XAttribute("Key", @"Software\Axiotic\Cliphoard\" + architecture), new XAttribute("Name", id), new XAttribute("Type", "integer"), new XAttribute("Value", "1"), new XAttribute("KeyPath", "yes")));
    if (relative == "Cliphoard.Windows.exe") { appFileId = id + "File"; component.Add(new XElement(wix + "Shortcut", new XAttribute("Id", "StartMenuShortcut"), new XAttribute("Directory", "ProgramMenuFolder"), new XAttribute("Name", "Cliphoard Windows"), new XAttribute("Target", "[INSTALLFOLDER]Cliphoard.Windows.exe"), new XAttribute("WorkingDirectory", "INSTALLFOLDER")));
        component.Add(new XElement(wix + "Shortcut", new XAttribute("Id", "DesktopShortcut"), new XAttribute("Directory", "DesktopFolder"), new XAttribute("Name", "Cliphoard Windows"), new XAttribute("Target", "[INSTALLFOLDER]Cliphoard.Windows.exe"), new XAttribute("WorkingDirectory", "INSTALLFOLDER")));
    }
    directory.Add(component); feature.Add(new XElement(wix + "ComponentRef", new XAttribute("Id", id)));
}
package.Add(new XElement(wix + "CustomAction", new XAttribute("Id", "CleanupStartup"), new XAttribute("FileRef", appFileId ?? throw new IOException("Application missing.")), new XAttribute("ExeCommand", "--cleanup-startup"), new XAttribute("Execute", "immediate"), new XAttribute("Return", "check")));
package.Add(new XElement(wix + "InstallExecuteSequence", new XElement(wix + "Custom", new XAttribute("Action", "CleanupStartup"), new XAttribute("Before", "RemoveFiles"), new XAttribute("Condition", "REMOVE=\"ALL\" AND NOT UPGRADINGPRODUCTCODE"))));
var cleanup = new XElement(wix + "Component", new XAttribute("Id", "DirectoryCleanup"), new XAttribute("Guid", StableGuid(architecture + ":directory-cleanup")),
    new XElement(wix + "RegistryValue", new XAttribute("Root", "HKCU"), new XAttribute("Key", @"Software\Axiotic\Cliphoard\" + architecture), new XAttribute("Name", "DirectoryCleanup"), new XAttribute("Type", "integer"), new XAttribute("Value", "1"), new XAttribute("KeyPath", "yes")));
int cleanupIndex = 0;
foreach (var directory in directories.Values.Append(programs)) cleanup.Add(new XElement(wix + "RemoveFolder", new XAttribute("Id", "Cleanup" + cleanupIndex++), new XAttribute("Directory", directory.Attribute("Id")!.Value), new XAttribute("On", "uninstall")));
install.Add(cleanup); feature.Add(new XElement(wix + "ComponentRef", new XAttribute("Id", "DirectoryCleanup")));
string wixSource = Path.Combine(output, "Installer.wxs"), wixProject = Path.Combine(output, "Installer.wixproj");
new XDocument(new XElement(wix + "Wix", package)).Save(wixSource);
new XDocument(new XElement("Project", new XAttribute("Sdk", "WixToolset.Sdk/4.0.6"), new XElement("PropertyGroup", new XElement("OutputName", Path.GetFileName(payload)), new XElement("InstallerPlatform", architecture), new XElement("OutputPath", output), new XElement("SuppressValidation", "true")))).Save(wixProject);
Run(dotnet, "build", wixProject, "-c", "Release", "-p:OutputPath=" + output + Path.DirectorySeparatorChar);

// Windows App SDK satellites expose language lists exceeding MSI's legacy column size.
// Keep file sizes, hashes and versions from WiX, mark packaged resources language-neutral,
// then run the complete MSI ICE validation on the final database. Failure stops packaging.
var installerType = Type.GetTypeFromProgID("WindowsInstaller.Installer") ?? throw new IOException("Windows Installer is unavailable.");
dynamic installer = Activator.CreateInstance(installerType)!;
dynamic database = installer.OpenDatabase(payload + ".msi", 1);
dynamic view = database.OpenView("UPDATE `File` SET `Language` = '0' WHERE `Language` IS NOT NULL");
view.Execute(); view.Close(); database.Commit();
System.Runtime.InteropServices.Marshal.FinalReleaseComObject(view);
System.Runtime.InteropServices.Marshal.FinalReleaseComObject(database);
System.Runtime.InteropServices.Marshal.FinalReleaseComObject(installer);
string wixTool = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @".nuget\packages\wixtoolset.sdk\4.0.6\tools\net6.0\wix.dll");
Run(dotnet, "exec", "--roll-forward", "LatestMajor", wixTool, "msi", "validate", payload + ".msi");

// Also create a structurally validated MSIX for environments with a publisher signing certificate.
string msixStage = Path.Combine(output, "msix-stage"); Directory.CreateDirectory(msixStage);
try
{
    foreach (string file in Directory.EnumerateFiles(payload, "*", SearchOption.AllDirectories))
    {
        string destination = Path.Combine(msixStage, Path.GetRelativePath(payload, file)); Directory.CreateDirectory(Path.GetDirectoryName(destination)!); File.Copy(file, destination);
    }
    var manifest = XDocument.Load(Path.Combine(root, @"ports\windows\Packaging\AppxManifest.xml"));
    var identity = manifest.Root!.Elements().First(element => element.Name.LocalName == "Identity"); identity.SetAttributeValue("Version", version); identity.SetAttributeValue("ProcessorArchitecture", architecture);
    manifest.Save(Path.Combine(msixStage, "AppxManifest.xml"));
    using (var brand = Image.FromFile(Path.Combine(payload, @"Assets\Brand.png")))
    foreach (var asset in new[] { ("StoreLogo", 50), ("Square150", 150), ("Square44", 44) })
    {
        using var bitmap = new Bitmap(asset.Item2, asset.Item2); using var graphics = Graphics.FromImage(bitmap); graphics.DrawImage(brand, 0, 0, bitmap.Width, bitmap.Height); bitmap.Save(Path.Combine(msixStage, "Assets", asset.Item1 + ".png"), ImageFormat.Png);
    }
    string sdk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"Windows Kits\10\bin");
    string hostArchitecture = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
    string makeAppx = Directory.EnumerateFiles(sdk, "makeappx.exe", SearchOption.AllDirectories).Where(path => Path.GetFileName(Path.GetDirectoryName(path)) == hostArchitecture).OrderDescending().First();
    Run(makeAppx, "pack", "/d", msixStage, "/p", payload + ".msix", "/o");
}
finally { Directory.Delete(msixStage, true); }
foreach (string artifact in new[] { payload + ".zip", payload + ".msi", payload + ".msix" }) Console.WriteLine(Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(artifact))) + "  " + artifact);

XElement GetDirectory(string relative)
{
    if (directories.TryGetValue(relative, out var existing)) return existing;
    XElement parent = GetDirectory(Path.GetDirectoryName(relative) ?? "");
    var directory = new XElement(wix + "Directory", new XAttribute("Id", "Directory" + directories.Count), new XAttribute("Name", Path.GetFileName(relative))); parent.Add(directory); directories[relative] = directory; return directory;
}
static string StableGuid(string value)
{
    byte[] bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value)); return new Guid(bytes.AsSpan(0, 16)).ToString("B");
}
static void Run(string executable, params string[] arguments)
{
    var info = new ProcessStartInfo(executable) { UseShellExecute = false };
    foreach (string argument in arguments) info.ArgumentList.Add(argument);
    using var process = Process.Start(info) ?? throw new IOException("Could not start build tool."); process.WaitForExit();
    if (process.ExitCode != 0) throw new IOException($"{Path.GetFileName(executable)} failed with exit {process.ExitCode}.");
}
