using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace Cliphoard.Windows;
internal static partial class MacHistoryArchive
{
    /// Authenticates one bounded chunk at a time. No plaintext archive is written to disk.
    private sealed class ChunkReader : Stream
    {
        private readonly Stream source;
        private readonly byte[] header, key;
        private readonly AesGcm cipher;
        private readonly int maximum;
        private readonly CancellationToken cancellation;
        private byte[] chunk = Array.Empty<byte>();
        private int position;
        private ulong index;
        private bool final;
        internal JsonObject Summary { get; }
        internal ChunkReader(Stream source, string passphrase, CancellationToken cancellation)
        {
            this.source = source; this.cancellation = cancellation; header = new byte[48]; source.ReadExactly(header);
            int rounds = BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(12)); maximum = BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(36));
            if (!header.AsSpan(0, 8).SequenceEqual("CLIPHRD1"u8) || BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(8)) != 1 || header[10] != 1 || header[11] != 1 || rounds is < 600000 or > 10000000 || maximum is < 65536 or > 8388608 || BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(40)) != 1040 || BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(44)) != 0) throw Invalid();
            key = Derive(passphrase, header.AsSpan(16, 16), rounds); cipher = new(key, 16);
            byte[] encrypted = new byte[1040], clear = new byte[1024];
            try
            {
                source.ReadExactly(encrypted); cipher.Decrypt(Nonce(header, 0), encrypted.AsSpan(0, 1024), encrypted.AsSpan(1024), clear, header);
                int length = Array.FindLastIndex(clear, value => value != 0) + 1;
                Summary = JsonNode.Parse(clear.AsSpan(0, length)) as JsonObject ?? throw Invalid();
                if (Summary["format"]?.GetValue<string>() != "cliphoard-archive" || Summary["version"]?.GetValue<int>() != 1) throw Invalid();
            }
            catch { cipher.Dispose(); CryptographicOperations.ZeroMemory(key); throw; }
            finally { CryptographicOperations.ZeroMemory(clear); }
        }
        public override int Read(Span<byte> destination)
        {
            cancellation.ThrowIfCancellationRequested();
            if (destination.Length == 0) return 0;
            if (position == chunk.Length)
            {
                if (final) return 0;
                CryptographicOperations.ZeroMemory(chunk); byte[] frame = new byte[5]; source.ReadExactly(frame);
                int length = BinaryPrimitives.ReadInt32BigEndian(frame);
                if (length is < 1 || length > maximum || frame[4] > 1) throw Invalid();
                byte[] sealedBytes = new byte[length + 16]; source.ReadExactly(sealedBytes); chunk = new byte[length];
                cipher.Decrypt(Nonce(header, checked(++index)), sealedBytes.AsSpan(0, length), sealedBytes.AsSpan(length), chunk, Aad(header, index, frame[4], length));
                final = frame[4] == 1; position = 0;
            }
            int count = Math.Min(destination.Length, chunk.Length - position); chunk.AsSpan(position, count).CopyTo(destination); position += count; return count;
        }
        internal void VerifyEnd() { if (ReadByte() != -1 || !final || source.ReadByte() != -1) throw Invalid(); }
        public override int Read(byte[] bytes, int offset, int count) => Read(bytes.AsSpan(offset, count));
        protected override void Dispose(bool disposing) { cipher.Dispose(); CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(chunk); base.Dispose(disposing); }
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { } public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long length) => throw new NotSupportedException(); public override void Write(byte[] bytes, int offset, int count) => throw new NotSupportedException();
    }
    private sealed class ChunkWriter : Stream
    {
        private readonly Stream destination;
        private readonly byte[] header, key, chunk = new byte[ChunkSize];
        private readonly AesGcm cipher;
        private readonly CancellationToken cancellation;
        private int count;
        private ulong index;
        internal long Written { get; private set; }
        internal ChunkWriter(Stream destination, JsonObject summary, string passphrase, CancellationToken cancellation)
        {
            this.destination = destination; this.cancellation = cancellation; header = new byte[48]; "CLIPHRD1"u8.CopyTo(header); header[9] = header[10] = header[11] = 1;
            BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(12), 600000); RandomNumberGenerator.Fill(header.AsSpan(16, 20)); BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(36), ChunkSize); BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(40), 1040);
            key = Derive(passphrase, header.AsSpan(16, 16), 600000); cipher = new(key, 16);
            byte[] clear = JsonSerializer.SerializeToUtf8Bytes(summary), padded = new byte[1024], encrypted = new byte[1040];
            try { if (clear.Length > padded.Length) throw Invalid(); clear.CopyTo(padded, 0); cipher.Encrypt(Nonce(header, 0), padded, encrypted.AsSpan(0, 1024), encrypted.AsSpan(1024), header); destination.Write(header); destination.Write(encrypted); }
            catch { cipher.Dispose(); CryptographicOperations.ZeroMemory(key); throw; }
            finally { CryptographicOperations.ZeroMemory(clear); CryptographicOperations.ZeroMemory(padded); }
        }
        public override void Write(ReadOnlySpan<byte> source)
        {
            while (!source.IsEmpty)
            {
                cancellation.ThrowIfCancellationRequested();
                if (count == chunk.Length) Seal(false);
                int take = Math.Min(source.Length, chunk.Length - count); source[..take].CopyTo(chunk.AsSpan(count)); count += take; Written += take; source = source[take..];
            }
        }
        private void Seal(bool final)
        {
            cancellation.ThrowIfCancellationRequested(); if (count == 0) throw Invalid();
            byte[] frame = new byte[count + 21]; BinaryPrimitives.WriteInt32BigEndian(frame, count); frame[4] = final ? (byte)1 : (byte)0;
            cipher.Encrypt(Nonce(header, checked(++index)), chunk.AsSpan(0, count), frame.AsSpan(5, count), frame.AsSpan(count + 5, 16), Aad(header, index, frame[4], count)); destination.Write(frame); CryptographicOperations.ZeroMemory(chunk); count = 0;
        }
        internal void Finish() => Seal(true);
        public override void Write(byte[] bytes, int offset, int count) => Write(bytes.AsSpan(offset, count));
        protected override void Dispose(bool disposing) { cipher.Dispose(); CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(chunk); base.Dispose(disposing); }
        public override bool CanRead => false; public override bool CanSeek => false; public override bool CanWrite => true;
        public override long Length => Written; public override long Position { get => Written; set => throw new NotSupportedException(); }
        public override void Flush() => destination.Flush(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long length) => throw new NotSupportedException(); public override int Read(byte[] bytes, int offset, int count) => throw new NotSupportedException();
    }
}
