using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;
namespace Cliphoard.Windows;

internal sealed class HistoryItem
{
    public MediaIndex? MediaIndex { get; set; }
    [JsonIgnore] internal string MediaText => string.Join('\n', MediaIndex?.Moments.Where(moment => moment.Text is not null).Select(moment => moment.Text) ?? Enumerable.Empty<string?>());
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    private string text = "";
    private string? textDigest;
    public string Text { get => text; set { text = value; textDigest = null; } }
    public string Source { get; set; } = "Windows";
    public string Kind { get; set; } = "Text";
    public DateTimeOffset Captured { get; set; } = DateTimeOffset.Now;
    public bool Pinned { get; set; }
    public DateTimeOffset? LastUsed { get; set; }
    public int UseCount { get; set; }
    public string? Shape { get; set; }
    public uint Format { get; set; } = 13;
    private byte[]? payload;
    private WeakReference<byte[]>? payloadCache;
    [JsonIgnore] internal Func<byte[]?>? PayloadLoader { get; private set; }
    [JsonIgnore] internal int PayloadLength { get; private set; }
    [JsonIgnore] internal string? PayloadDigest { get; private set; }
    [JsonIgnore] internal bool PayloadChanged { get; private set; }
    public byte[]? Payload
    {
        get
        {
            if (payload is not null) return payload;
            if (payloadCache is not null && payloadCache.TryGetTarget(out byte[]? cached)) return cached;
            byte[]? loaded = PayloadLoader?.Invoke();
            if (loaded is not null) payloadCache = new(loaded);
            return loaded;
        }
        set
        {
            payload = value; payloadCache = null; PayloadLoader = null; PayloadLength = value?.Length ?? 0;
            PayloadDigest = value is null ? null : Convert.ToHexString(SHA256.HashData(value)); PayloadChanged = true;
        }
    }
    internal void AttachPayload(Func<byte[]?> loader, int length, string? digest, bool retainCached = true)
    {
        if (!retainCached) payloadCache = null;
        else if (payload is not null) payloadCache = new(payload);
        payload = null; PayloadLoader = loader; PayloadLength = length; PayloadDigest = digest; PayloadChanged = false;
    }
    public byte[]? RichText { get; set; }
    public byte[]? Html { get; set; }
    [JsonIgnore] internal ContentSafety.RepresentationSafety? RepresentationSafety { get; set; }
    public List<string> Tags { get; set; } = new();
    public List<string> DismissedSuggestions { get; set; } = new();
    public string? OcrText { get; set; }
    public string? DocumentText { get; set; }
    public bool DocumentTruncated { get; set; }
    public string? Transcript { get; set; }
    public string? MacMetadata { get; set; }
    public List<MacArchiveRecord> MacRecords { get; set; } = new();
    [JsonConverter(typeof(ClipFlagsConverter))] public long Flags { get; set; }
    [JsonIgnore] internal bool AnalysisNsfwAllowed { get; set; }
    [JsonIgnore] public bool AnalysisVetoed => ((Flags | ContentSafety.AlternateFlags(this)) & ~(AnalysisNsfwAllowed ? 136L : 8L)) != 0 || !AnalysisNsfwAllowed && NsfwPolicy.Labelled(this);
    [JsonIgnore] public string SearchText => AnalysisVetoed ? "" : Text + "\n" + OcrText + "\n" + Transcript + "\n" + string.Join(" ", Tags);
    [JsonIgnore] public string? ArchiveFingerprint { get; set; }
    [JsonIgnore] public string Title => Kind == "Image" ? "Copied image" : Text.Split('\n')[0].Trim();
    [JsonIgnore] public string Fingerprint => PayloadDigest ?? (textDigest ??= Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Text))));
}
internal enum DiagnosticKind { Capture, PanelShown, PasteSubmitted, PasteRefused, SessionSuspended, SessionResumed }
internal sealed record DiagnosticEntry(long At, DiagnosticKind Event);
internal sealed class HistoryState
{
    public bool DebugLogging { get; set; }
    public List<DiagnosticEntry> Diagnostics { get; set; } = new();
    public bool AutomaticReleaseChecks { get; set; }
    public long LastReleaseCheck { get; set; }
    public string SearchModality { get; set; } = "text";
    public bool SearchTextEnabled { get; set; } = true;
    public bool SearchImagesEnabled { get; set; } = true;
    public bool SearchAudioEnabled { get; set; }
    public bool SearchVideoEnabled { get; set; }
    public string MediaPreset { get; set; } = "balanced";
    public string MediaSpeechCoverage { get; set; } = "sampled";
    public string AgentPermission { get; set; } = "askEveryTime";
    public bool AgentNotifications { get; set; }
    public bool OnboardingCompleted { get; set; }
    public string LicenceKey { get; set; } = "";
    public string Theme { get; set; } = "system";
    public string Layout { get; set; } = "strip";
    public int PreviewHeight { get; set; } = 250;
    public int Limit { get; set; } = 200;
    public bool Paused { get; set; }
    internal static readonly Dictionary<string, string> CaptureSounds = new()
    {
        ["copy-tick"] = "Soft tick", ["copy-click"] = "Click", ["copy-pop"] = "Pop", ["copy-bubble"] = "Bubble",
        ["copy-glass"] = "Glass", ["copy-bell"] = "Bell", ["copy-chime"] = "Chime", ["copy-pluck"] = "Pluck",
        ["copy-drop"] = "Drop", ["copy-ripple"] = "Ripple", ["copy-wood"] = "Woodblock", ["copy-sparkle"] = "Sparkle",
        ["SystemAsterisk"] = "Asterisk", ["SystemDefault"] = "Default", ["SystemExclamation"] = "Exclamation", ["SystemHand"] = "Critical stop", ["SystemQuestion"] = "Question"
    };
    public string SoundName { get; set; } = "SystemAsterisk";
    public bool TakeFocusOnSummon { get; set; } = true;
    public bool SoundEnabled { get; set; }
    public bool NsfwEnabled { get; set; } = true;
    public bool NsfwFocusOnly { get; set; }
    public bool NsfwText { get; set; } = true;
    public bool NsfwImages { get; set; } = true;
    public bool NsfwAudio { get; set; } = true;
    public bool NsfwVideo { get; set; } = true;
    public bool DocumentTextEnabled { get; set; }
    public bool PdfTextEnabled { get; set; } = true;
    public bool RichTextEnabled { get; set; } = true;
    public bool DocumentTagsEnabled { get; set; } = true;
    public bool OcrEnabled { get; set; }
    public string ImageModel { get; set; } = "openvision-tiny-p8";
    public string SpeechModel { get; set; } = "turbo";
    public string SemanticModel { get; set; } = "all-MiniLM-L6-v2";
    public int OgmaDimension { get; set; } = 1024;
    public string SearchMode { get; set; } = "exact";
    public string SearchTiming { get; set; } = "pause";
    public List<string> TagOverlays { get; set; } = new();
    public List<string> CustomTagNames { get; set; } = new();
    public bool CustomBasket { get; set; }
    public double TagThreshold { get; set; } = .28;
    public List<string> ExcludedApps { get; set; } = new();
    public List<HistoryItem> Items { get; set; } = new();
}

/// Current-user DPAPI, atomic ciphertext replacement, and bounded storage. No plaintext sidecars.
internal sealed class HistoryStore
{
    private readonly string path;
    private readonly HistoryDatabase database;
    private SuspendedHistory? suspended;
    internal string DirectoryPath => Path.GetDirectoryName(path)!;
    internal HistoryState State { get; private set; } = new();
    internal bool Writable { get; private set; } = true;
    internal bool UnsavedChanges { get; private set; }
    internal event Action<string>? PersistenceFailed;
    internal string? Error { get; private set; }
    internal HistoryStore(string? directory = null)
    {
        directory ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cliphoard");
        path = Path.Combine(directory, "history.dpapi"); database = new(directory);
        try
        {
            Directory.CreateDirectory(directory);
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException();
            using (var identity = WindowsIdentity.GetCurrent())
            {
                var acl = new DirectorySecurity();
                acl.SetAccessRuleProtection(true, false);
                foreach (SecurityIdentifier sid in new[] { identity.User ?? throw new IOException(), new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
                    acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                new DirectoryInfo(directory).SetAccessControl(acl);
            }
            Load();
        }
        catch { Writable = false; Error = "History could not be opened. This session stays in memory; the saved file is preserved."; }
    }
    internal void Suspend()
    {
        try { if (UnsavedChanges && suspended is null) suspended = new SuspendedHistory(State); }
        catch { Error = "Unsaved changes could not be retained for session recovery."; }
        finally { State.Items.Clear(); }
    }
    internal void Load()
    {
        if (suspended is not null)
        {
            State = suspended.Restore(); suspended.Dispose(); suspended = null; NormalizeLoadedState(); return;
        }
        if (database.Exists)
        {
            HistoryState loaded = database.Load(); ValidateState(loaded); State = loaded; NormalizeLoadedState(); return;
        }
        if (!File.Exists(path)) return;
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || new FileInfo(path).Length > 48 * 1024 * 1024) throw new IOException();
        byte[] clear = Protect(File.ReadAllBytes(path), false);
        try
        {
            HistoryState state = JsonSerializer.Deserialize<HistoryState>(clear) ?? throw new IOException();
            ValidateState(state);
            state.Theme = DesktopThemes.Validate(state.Theme); state.Layout = DesktopThemes.ValidateLayout(state.Layout); state.PreviewHeight = DesktopThemes.Height(state.PreviewHeight);
            foreach (HistoryItem item in state.Items) item.Flags |= ContentSafety.ItemFlags(item);
            State = state; NormalizeLoadedState(); database.Save(State);
        }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }
    private void NormalizeLoadedState()
    {
        State.Theme = DesktopThemes.Validate(State.Theme); State.Layout = DesktopThemes.ValidateLayout(State.Layout); State.PreviewHeight = DesktopThemes.Height(State.PreviewHeight);
        foreach (HistoryItem item in State.Items) item.Flags |= ContentSafety.ItemFlags(item);
        Trim(); Reorder();
    }
    internal static void ValidateState(HistoryState state)
    {
        if (state.Diagnostics is null || state.Diagnostics.Count > 256 || state.Diagnostics.Any(entry => entry is null || entry.At is < 0 or > 253402300799 || !Enum.IsDefined(entry.Event))) throw new IOException("Invalid diagnostic metadata.");
        if (state.SearchModality is not ("all" or "text" or "images" or "audio" or "video") || state.MediaPreset is not ("lightweight" or "balanced" or "detailed") || state.MediaSpeechCoverage is not ("off" or "sampled" or "full")) throw new IOException("Invalid media preferences.");
        foreach (HistoryItem item in state.Items ?? throw new IOException("History contents are unavailable.")) item?.MediaIndex?.Validate();
        if (state.Items is null || state.Items.Any(i => i is null)) throw new IOException("History contents are invalid.");
        if (state.Limit is < 0 or > 5000 || state.Items.Any(i => i.Text is null || i.Source is null || i.Source.Length > 200 || i.Text.Length > 65536 || i.Text.Contains('\0') || (i.Payload?.Length ?? 0) > 8 * 1024 * 1024 || (i.RichText?.Length ?? 0) > 512 * 1024 || (i.Html?.Length ?? 0) > 512 * 1024 || i.Tags is null || i.Tags.Count > 20 || i.Tags.Any(t => t is null || t.Length > 40) || i.Format is not (0 or 13 or 8 or 17 or 15) || i.Format == 0 && (i.Payload is null || !ClipboardContent.IsPng(i.Payload)))) throw new IOException();
        if (state.TagOverlays is null || state.TagOverlays.Count > TagCatalog.BuiltIn.Length || state.TagOverlays.Any(id => !TagCatalog.BuiltIn.Any(basket => basket.Id == id)) || state.TagOverlays.Distinct().Count() != state.TagOverlays.Count || state.CustomTagNames is null || state.CustomTagNames.Count > 2000 || state.CustomTagNames.Any(name => name is null || name.Length > 80) || !double.IsFinite(state.TagThreshold) || state.TagThreshold is < 0 or > 1 || state.Items.Any(item => item.DismissedSuggestions is null || item.DismissedSuggestions.Count > 2000 || item.DismissedSuggestions.Any(tag => tag is null || tag.Length > 80))) throw new IOException("Invalid tag preferences.");
        if (state.AgentPermission is not ("askEveryTime" or "fullAccess")) throw new IOException("Invalid remembered agent permission.");
        if (state.SoundName is null || !HistoryState.CaptureSounds.ContainsKey(state.SoundName)) throw new IOException("Invalid capture sound.");
        if (state.LicenceKey is null || state.LicenceKey.Length > 16384) throw new IOException("Invalid licence metadata.");
        if (state.SearchTiming is not ("instant" or "pause" or "enter")) throw new IOException("Invalid search timing.");
        if (!ModelCatalog.Images.Contains(state.ImageModel) || !ModelCatalog.Speech.ContainsKey(state.SpeechModel) || !ModelCatalog.Text.Any(model => model.Id == state.SemanticModel) || state.OgmaDimension is not (384 or 1024)) throw new IOException("Invalid model preference.");
        if (state.SearchMode is not ("exact" or "essence" or "tag" or "neural" or "smart" or "image") || state.Items.Any(i => i.DocumentText?.Length > 200000 || i.OcrText?.Length > 65536 || i.Transcript?.Length > 200000 || i.MacMetadata?.Length > 1024 * 1024 || i.MacRecords is null || i.MacRecords.Count > 2001 || i.MacRecords.Any(r => r is null || r.Type is not (3 or 4) || !Guid.TryParse(r.Name, out _) || r.Body is null || r.Body.Length > 1024 * 1024))) throw new IOException("Invalid analysis metadata.");
        foreach (var record in state.Items.SelectMany(item => item.MacRecords)) MacHistoryArchive.ValidateSupplementary(record);
        if (state.ExcludedApps is null || state.ExcludedApps.Count > 100 || state.ExcludedApps.Any(a => a is null || a.Length > 200)) throw new IOException();
        if (state.Items.Any(item => item.UseCount < 0 || item.Shape?.Length > 40)) throw new IOException("Invalid usage metadata.");
        if (state.Items.Any(i => i.Kind == "Image" ? i.Format is not (0 or 8 or 17) : i.Kind == "Files" ? i.Format != 15 || i.Payload is null || ClipboardContent.DropText(i.Payload) != i.Text : i.Format != 13 || i.Payload is not null)) throw new IOException("Clip type and payload disagree.");
        if (state.Items.Any(i => i.Html is not null && ClipboardContent.HtmlText(i.Html) is null)) throw new IOException("Invalid HTML payload.");
        if (state.Items.Any(i => i.Format is 8 or 17 && (i.Payload is null || !HistoryClipboard.ValidDib(i.Payload)) || i.Kind == "Color" && !ContentClassifier.IsColor(i.Text))) throw new IOException("Invalid image or color payload.");
        if (state.Items.Any(item => Size(item) > 24 * 1024 * 1024)) throw new IOException("Clip exceeds its storage bound.");
        if (state.Items.Select(i => i.Id).Distinct().Count() != state.Items.Count || state.Items.Any(i => !Guid.TryParse(i.Id, out _) || i.Kind is not ("Text" or "Code" or "Link" or "Color" or "Image" or "Files"))) throw new IOException("History has invalid or excessive contents.");
    }
    internal static bool SameContent(HistoryItem first, HistoryItem second)
    {
        if (first.Kind == "Image" && second.Kind == "Image" && first.ArchiveFingerprint is not null && second.ArchiveFingerprint is not null)
            return first.ArchiveFingerprint == second.ArchiveFingerprint;
        return first.Format == second.Format && first.Fingerprint == second.Fingerprint;
    }
    private static bool IncludeNew(HashSet<string> native, HashSet<string> images, HistoryItem item)
    {
        string key = item.Format.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" + item.Fingerprint;
        bool duplicate = native.Contains(key) || item.Kind == "Image" && item.ArchiveFingerprint is string image && images.Contains(image);
        if (duplicate) return false;
        native.Add(key); if (item.Kind == "Image" && item.ArchiveFingerprint is string fingerprint) images.Add(fingerprint);
        return true;
    }
    internal static int NewContentCount(IEnumerable<HistoryItem> existing, IEnumerable<HistoryItem> incoming)
    {
        var native = new HashSet<string>(StringComparer.Ordinal); var images = new HashSet<string>(StringComparer.Ordinal);
        foreach (HistoryItem item in existing) IncludeNew(native, images, item);
        return incoming.Count(item => IncludeNew(native, images, item));
    }
    internal int Import(IEnumerable<HistoryItem> incoming, bool expandLimit)
    {
        if (!Writable) throw new IOException("History storage is unavailable; the saved file has been preserved.");
        var merged = State.Items.ToList(); int added = 0;
        var native = new HashSet<string>(StringComparer.Ordinal); var images = new HashSet<string>(StringComparer.Ordinal);
        foreach (HistoryItem item in merged) IncludeNew(native, images, item);
        foreach (var item in incoming)
        {
            item.Flags |= ContentSafety.ItemFlags(item);
            if (!IncludeNew(native, images, item)) continue;
            item.Id = Guid.NewGuid().ToString("N"); merged.Add(item); ++added;
        }
        int nextLimit = expandLimit && State.Limit != 0 ? Math.Max(500, State.Limit) : State.Limit;
        if (nextLimit != 0 && merged.Count(item => !item.Pinned) > nextLimit) throw new IOException("This import would exceed your history limit. Nothing was imported.");
        var original = State.Items; int previousLimit = State.Limit;
        State.Items = merged.OrderByDescending(i => i.Captured).ToList(); State.Limit = nextLimit; Save();
        if (!Writable) { State.Items = original; State.Limit = previousLimit; throw new IOException("History could not be saved. Nothing was imported."); }
        return added;
    }
    internal void Add(HistoryItem item)
    {
        item.Flags |= ContentSafety.ItemFlags(item);
        string fingerprint = item.Fingerprint;
        HistoryItem? prior = State.Items.FirstOrDefault(i => i.Fingerprint == fingerprint && i.Format == item.Format);
        if (prior is not null) { item.Captured = prior.Captured; item.UseCount = prior.UseCount; item.MediaIndex = prior.MediaIndex; item.Pinned = prior.Pinned; item.Tags = prior.Tags; item.DismissedSuggestions = prior.DismissedSuggestions; item.OcrText = prior.OcrText; item.Transcript = prior.Transcript; item.DocumentText = prior.DocumentText; item.DocumentTruncated = prior.DocumentTruncated; item.Flags |= prior.Flags; item.MacMetadata = prior.MacMetadata; item.MacRecords = prior.MacRecords; item.Id = prior.Id; State.Items.Remove(prior); }
        item.LastUsed = DateTimeOffset.Now; item.Shape = ContentShape.Of(item.Text, item.Kind);
        State.Items.Insert(0, item); Reorder(); Trim(); Save(); RecordDiagnostic(DiagnosticKind.Capture);
    }
    internal bool SaveAgentNote(string requestId, string text)
    {
        if (!Writable || !Guid.TryParseExact(requestId, "D", out Guid parsed) || string.IsNullOrWhiteSpace(text) || text.Contains('\0') || System.Text.Encoding.UTF8.GetByteCount(text) > 32768 || ContentSafety.Flags(text, "Cliphoard Agent") != 0 || NsfwPolicy.Labelled(new HistoryItem { Text = text })) return false;
        string id = parsed.ToString("N");
        HistoryItem? existing = State.Items.FirstOrDefault(item => item.Id == id);
        if (existing is not null) return existing.Kind == "Text" && existing.Text == text && existing.Source == "Cliphoard Agent" && existing.Pinned && existing.Flags == 0
            && existing.Tags.SequenceEqual(new[] { "agent-note", "agent-share" }) && existing.PayloadLength == 0 && existing.RichText is null && existing.Html is null && existing.OcrText is null && existing.Transcript is null && existing.DocumentText is null;
        var note = new HistoryItem { Id = id, Text = text, Source = "Cliphoard Agent", Pinned = true, LastUsed = DateTimeOffset.Now, Tags = new() { "agent-note", "agent-share" } };
        State.Items.Add(note); Reorder(); Save(); return Writable && !UnsavedChanges;
    }
    internal void ForgetImageUnderstanding()
    {
        if (!Writable) throw new IOException("History storage is unavailable.");
        var metadata = new Dictionary<HistoryItem, string?>();
        foreach (HistoryItem item in State.Items.Where(item => item.Kind == "Image"))
        {
            var node = item.MacMetadata is string json ? System.Text.Json.Nodes.JsonNode.Parse(json) as System.Text.Json.Nodes.JsonObject ?? throw new IOException("Image metadata is unavailable.") : null;
            node?.Remove("ocrText"); metadata[item] = node?.ToJsonString();
        }
        foreach (var pair in metadata) { pair.Key.OcrText = ""; pair.Key.MacMetadata = pair.Value; pair.Key.MacRecords.RemoveAll(record => record.Type == 3); }
        Save(); if (!Writable || UnsavedChanges) throw new IOException("Image understanding could not be saved.");
        database.Compact();
    }
    internal static long Size(HistoryItem item) => (item.MediaIndex?.Moments.Sum(moment => moment.Vector.LongLength + (moment.Text?.Length ?? 0) * 2L) ?? 0) + item.PayloadLength + (item.RichText?.LongLength ?? 0) + (item.Html?.LongLength ?? 0) + item.Text.Length * 2L + (item.OcrText?.Length ?? 0) * 2L + (item.Transcript?.Length ?? 0) * 2L + (item.DocumentText?.Length ?? 0) * 2L + (item.MacMetadata?.Length ?? 0) * 2L + item.MacRecords.Sum(r => r.Body.LongLength) + item.Tags.Sum(t => t.Length * 2L);
    internal bool CanPin(HistoryItem item) => !item.Pinned;
    internal void Trim()
    {
        while (State.Limit != 0 && State.Items.Count(item => !item.Pinned) > State.Limit)
        {
            HistoryItem? last = State.Items.LastOrDefault(i => !i.Pinned);
            if (last is null) break;
            State.Items.Remove(last);
        }
    }
    internal void Reorder() => State.Items = State.Items.OrderByDescending(item => item.Pinned).ThenByDescending(item => item.LastUsed ?? item.Captured).ThenBy(item => item.Id, StringComparer.Ordinal).ToList();
    internal void MarkUsed(HistoryItem item)
    {
        HistoryItem? stored = State.Items.FirstOrDefault(candidate => candidate.Id == item.Id);
        if (stored is null) return;
        stored.LastUsed = DateTimeOffset.Now;
        if (stored.UseCount < int.MaxValue) ++stored.UseCount;
        Reorder(); Save();
    }
    internal void RecordDiagnostic(DiagnosticKind kind)
    {
        if (!State.DebugLogging) return;
        State.Diagnostics.Add(new(DateTimeOffset.UtcNow.ToUnixTimeSeconds(), kind));
        if (State.Diagnostics.Count > 256) State.Diagnostics.RemoveRange(0, State.Diagnostics.Count - 256);
        Save();
    }
    internal void Save()
    {
        if (!Writable) { UnsavedChanges = true; return; }
        try { ValidateState(State); database.Save(State); UnsavedChanges = false; }
        catch { Writable = false; UnsavedChanges = true; Error = "Saving history failed. New changes are held in memory. Your existing saved history is preserved."; PersistenceFailed?.Invoke(Error); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct Blob { internal int Size; internal nint Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptProtectData(ref Blob input, string? description, nint entropy, nint reserved, nint prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptUnprotectData(ref Blob input, nint description, nint entropy, nint reserved, nint prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint memory);
    internal static byte[] Protect(byte[] bytes, bool encrypt)
    {
        nint memory = Marshal.AllocHGlobal(bytes.Length);
        Blob output = default;
        try
        {
            Marshal.Copy(bytes, 0, memory, bytes.Length); Blob input = new() { Size = bytes.Length, Data = memory };
            bool ok = encrypt ? CryptProtectData(ref input, null, 0, 0, 0, 1, out output) : CryptUnprotectData(ref input, 0, 0, 0, 0, 1, out output);
            if (!ok || output.Size < 0 || output.Size > 48 * 1024 * 1024) throw new CryptographicException();
            byte[] result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally { for (int i = 0; i < bytes.Length; ++i) Marshal.WriteByte(memory, i, 0); Marshal.FreeHGlobal(memory); if (output.Data != 0) { if (!encrypt) for (int i = 0; i < output.Size; ++i) Marshal.WriteByte(output.Data, i, 0); LocalFree(output.Data); } }
    }
}
