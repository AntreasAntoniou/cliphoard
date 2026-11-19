using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;
namespace Cliphoard.Windows;

/// Data-only Apple property lists. Object graphs, nesting and all lengths are bounded.
internal static class PropertyList
{
    internal static object? Read(byte[] bytes)
    {
        if (bytes.Length > 16 * 1024 * 1024) throw new IOException("Property list exceeds its bound.");
        if (bytes.AsSpan().StartsWith("bplist00"u8)) return new Binary(bytes).Read();
        using var stream = new MemoryStream(bytes, false);
        using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null, MaxCharactersInDocument = 32 * 1024 * 1024 });
        var root = XDocument.Load(reader).Root;
        if (root?.Name != "plist" || root.Elements().Count() != 1) throw new IOException("Invalid property list.");
        int nodes = 0;
        object? Parse(XElement element, int depth)
        {
            if (depth > 64 || ++nodes > 100000) throw new IOException("Property list graph exceeds its bound.");
            switch (element.Name.LocalName)
            {
                case "string": return element.Value;
                case "integer": return long.Parse(element.Value, CultureInfo.InvariantCulture);
                case "real": return double.Parse(element.Value, CultureInfo.InvariantCulture);
                case "date": return DateTimeOffset.Parse(element.Value, CultureInfo.InvariantCulture);
                case "data": return Convert.FromBase64String(element.Value);
                case "true": return true;
                case "false": return false;
                case "array": return element.Elements().Select(child => Parse(child, depth + 1)).ToArray();
                case "dict":
                    XElement[] children = element.Elements().ToArray();
                    if (children.Length % 2 != 0) throw new IOException("Invalid property dictionary.");
                    var values = new Dictionary<string, object?>(StringComparer.Ordinal);
                    for (int index = 0; index < children.Length; index += 2)
                        if (children[index].Name != "key" || !values.TryAdd(children[index].Value, Parse(children[index + 1], depth + 1))) throw new IOException("Duplicate or invalid property key.");
                    return values;
                default: throw new IOException("Unsupported property type.");
            }
        }
        return Parse(root.Elements().Single(), 0);
    }
    private sealed class Binary
    {
        private readonly byte[] bytes;
        private readonly int offsetSize, referenceSize, count, top, table;
        private readonly HashSet<int> active = new();
        private int visited;
        internal Binary(byte[] bytes)
        {
            this.bytes = bytes;
            if (bytes.Length < 40) throw new IOException("Truncated binary property list.");
            int trailer = bytes.Length - 32; offsetSize = bytes[trailer + 6]; referenceSize = bytes[trailer + 7];
            count = checked((int)Number(trailer + 8, 8)); top = checked((int)Number(trailer + 16, 8)); table = checked((int)Number(trailer + 24, 8));
            if (offsetSize is < 1 or > 8 || referenceSize is < 1 or > 8 || count is < 1 or > 100000 || top >= count || table < 8 || (long)table + (long)count * offsetSize > trailer) throw new IOException("Invalid binary property table.");
        }
        internal object? Read() => Object(top, 0);
        private ulong Number(int position, int width)
        {
            if (width is < 1 or > 8 || position < 0 || position > bytes.Length - width) throw new IOException("Invalid property integer.");
            ulong value = 0; for (int index = 0; index < width; ++index) value = (value << 8) | bytes[position + index]; return value;
        }
        private int Length(int nibble, ref int position)
        {
            if (nibble != 15) return nibble;
            int marker = checked((int)Number(position++, 1));
            if (marker >> 4 != 1 || (marker & 15) > 3) throw new IOException("Invalid property length.");
            int width = 1 << (marker & 15); int value = checked((int)Number(position, width)); position += width; return value;
        }
        private object? Object(int reference, int depth)
        {
            if (reference < 0 || reference >= count || depth > 64 || ++visited > 100000 || !active.Add(reference)) throw new IOException("Invalid property object graph.");
            try
            {
                int position = checked((int)Number(checked(table + reference * offsetSize), offsetSize));
                if (position < 8 || position >= table) throw new IOException("Invalid property offset.");
                int marker = bytes[position++], kind = marker >> 4, nibble = marker & 15;
                if (kind == 0) return nibble switch { 0 => null, 8 => false, 9 => true, _ => throw new IOException("Unsupported property marker.") };
                if (kind == 1)
                {
                    if (nibble > 3) throw new IOException("Oversized property integer.");
                    int width = 1 << nibble; ulong value = Number(position, width);
                    return width == 8 ? unchecked((long)value) : (long)value;
                }
                if (kind is 2 or 3)
                {
                    int width = kind == 3 ? 8 : 1 << nibble;
                    double value = width switch { 4 => BitConverter.Int32BitsToSingle(unchecked((int)Number(position, 4))), 8 => BitConverter.Int64BitsToDouble(unchecked((long)Number(position, 8))), _ => throw new IOException("Invalid property real.") };
                    if (!double.IsFinite(value)) throw new IOException("Nonfinite property real.");
                    return kind == 3 ? (object)DateTimeOffset.UnixEpoch.AddSeconds(978307200 + value) : value;
                }
                int length = Length(nibble, ref position);
                int widthBytes = kind == 6 ? 2 : kind is 10 or 13 ? referenceSize : 1;
                long size = (long)length * widthBytes * (kind == 13 ? 2 : 1);
                if (size > 16 * 1024 * 1024 || position > table - size) throw new IOException("Property payload exceeds its bound.");
                switch (kind)
                {
                    case 4: return bytes.AsSpan(position, length).ToArray();
                    case 5: return new UTF8Encoding(false, true).GetString(bytes, position, length);
                    case 6: return new UnicodeEncoding(true, false, true).GetString(bytes, position, checked(length * 2));
                    case 10:
                        var array = new object?[length];
                        for (int index = 0; index < length; ++index) array[index] = Object(checked((int)Number(position + index * referenceSize, referenceSize)), depth + 1);
                        return array;
                    case 13:
                        var dictionary = new Dictionary<string, object?>(StringComparer.Ordinal);
                        for (int index = 0; index < length; ++index)
                        {
                            object? key = Object(checked((int)Number(position + index * referenceSize, referenceSize)), depth + 1);
                            object? value = Object(checked((int)Number(position + (length + index) * referenceSize, referenceSize)), depth + 1);
                            if (key is not string text || !dictionary.TryAdd(text, value)) throw new IOException("Invalid property dictionary key.");
                        }
                        return dictionary;
                    default: throw new IOException("Unsupported property object.");
                }
            }
            finally { active.Remove(reference); }
        }
    }
}
