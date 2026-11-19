using System.Globalization;
using System.Text;

namespace Cliphoard.Windows;

internal static class RtfText
{
    internal static string Read(byte[] bytes, int maximumCharacters, CancellationToken cancellation, bool includeHidden = false)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        string source = Encoding.Latin1.GetString(bytes);
        if (!source.StartsWith("{\\rtf", StringComparison.Ordinal)) throw new IOException("Invalid RTF document.");
        var output = new StringBuilder();
        var groups = new Stack<(bool Skip, int UnicodeFallback, int CodePage)>();
        bool skip = false;
        int unicodeFallback = 1, codePage = 1252, fallback = 0;
        Decoder decoder = Encoding.GetEncoding(codePage, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetDecoder();
        byte[] single = new byte[1]; char[] decoded = new char[2];
        void Flush()
        {
            int count = decoder.GetChars(Array.Empty<byte>(), 0, 0, decoded, 0, true);
            output.Append(decoded, 0, count);
        }
        void AppendByte(byte value)
        {
            single[0] = value;
            int count = decoder.GetChars(single, 0, 1, decoded, 0, false);
            output.Append(decoded, 0, count);
        }
        var ignored = new HashSet<string>(StringComparer.Ordinal) { "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "objdata", "header", "footer", "xmlnstbl", "datastore", "themedata", "fldinst" };
        for (int index = 0; index < source.Length && output.Length < maximumCharacters; ++index)
        {
            if (index % 4096 == 0) cancellation.ThrowIfCancellationRequested();
            char character = source[index];
            if (character == '{') { Flush(); if (groups.Count >= 256) throw new IOException("RTF nesting exceeds the parser limit."); groups.Push((skip, unicodeFallback, codePage)); continue; }
            if (character == '}') { Flush(); if (groups.Count == 0) throw new IOException("Unbalanced RTF document."); (skip, unicodeFallback, codePage) = groups.Pop(); decoder = Encoding.GetEncoding(codePage, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetDecoder(); continue; }
            if (character is '\r' or '\n') continue;
            if (character != '\\')
            {
                if (fallback > 0) --fallback;
                else if (!skip) AppendByte((byte)character);
                continue;
            }
            if (++index >= source.Length) throw new IOException("Truncated RTF escape.");
            character = source[index];
            if (character is '\\' or '{' or '}') { if (fallback > 0) --fallback; else if (!skip) AppendByte((byte)character); continue; }
            if (character == '*') { Flush(); if (!includeHidden) skip = true; continue; }
            if (character == '\'')
            {
                if (index + 2 >= source.Length || !byte.TryParse(source.AsSpan(index + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out byte value)) throw new IOException("Invalid RTF character escape.");
                index += 2;
                if (fallback > 0) --fallback;
                else if (!skip) AppendByte(value);
                continue;
            }
            Flush();
            if (!char.IsAsciiLetter(character)) { if (!skip && character == '~') output.Append('\u00a0'); continue; }
            int start = index;
            while (index < source.Length && char.IsAsciiLetter(source[index])) ++index;
            string word = source[start..index];
            int numberStart = index;
            if (index < source.Length && source[index] == '-') ++index;
            while (index < source.Length && char.IsAsciiDigit(source[index])) ++index;
            int.TryParse(source.AsSpan(numberStart, index - numberStart), NumberStyles.Integer, CultureInfo.InvariantCulture, out int number);
            bool hasNumber = index > numberStart;
            if (index >= source.Length || source[index] != ' ') --index;
            if (includeHidden && word is "pict" or "object" or "objdata" or "datastore" or "bin") throw new IOException("Embedded RTF data requires verification.");
            if (!includeHidden && ignored.Contains(word)) skip = true;
            if (word == "bin" && hasNumber)
            {
                if (number < 0 || number > source.Length - index - 1) throw new IOException("Invalid RTF binary block.");
                index += number; continue;
            }
            if (word == "uc" && hasNumber) { if (number is < 0 or > 16) throw new IOException("Invalid RTF Unicode fallback."); unicodeFallback = number; }
            if (word == "ansicpg" && hasNumber) { decoder = Encoding.GetEncoding(number, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetDecoder(); codePage = number; }
            if (skip) continue;
            if (word == "u" && hasNumber) { output.Append(unchecked((char)(short)number)); fallback = unicodeFallback; }
            else if (word is "par" or "line") output.Append('\n');
            else if (word == "tab") output.Append('\t');
            else if (word == "emdash") output.Append('\u2014');
            else if (word == "endash") output.Append('\u2013');
            else if (word == "bullet") output.Append('\u2022');
        }
        if (output.Length < maximumCharacters) { Flush(); if (groups.Count != 0) throw new IOException("Truncated RTF group."); }
        int limit = Math.Min(output.Length, maximumCharacters);
        if (limit > 0 && char.IsHighSurrogate(output[limit - 1])) --limit;
        string result = output.ToString(0, limit); _ = new UTF8Encoding(false, true).GetByteCount(result); return result;
    }
}
