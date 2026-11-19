using System.Buffers.Binary;
using System.Numerics;
namespace Cliphoard.Windows;

// The permutation and constants follow the shipping Mac Keccak-256 implementation.
internal static class Keccak256
{
    private static readonly ulong[] RoundConstants = { 0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008, };
    private static readonly int[] RotationOffsets = { 1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
        27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44, };
    private static readonly int[] PiLane = { 10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
        15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1, };
    internal static byte[] Hash(byte[] input)
    {
        const int rate = 136;
        byte[] message = new byte[((input.Length + 1 + rate - 1) / rate) * rate];
        input.CopyTo(message, 0); message[input.Length] = 1; message[^1] |= 0x80;
        var state = new ulong[25];
        for (int offset = 0; offset < message.Length; offset += rate)
        {
            for (int lane = 0; lane < rate / 8; ++lane) state[lane] ^= BinaryPrimitives.ReadUInt64LittleEndian(message.AsSpan(offset + lane * 8));
            Permute(state);
        }
        var digest = new byte[32];
        for (int lane = 0; lane < 4; ++lane) BinaryPrimitives.WriteUInt64LittleEndian(digest.AsSpan(lane * 8), state[lane]);
        return digest;
    }
    private static void Permute(ulong[] state)
    {
        var lanes = new ulong[5];
        foreach (ulong round in RoundConstants)
        {
            for (int index = 0; index < 5; ++index) lanes[index] = state[index] ^ state[index + 5] ^ state[index + 10] ^ state[index + 15] ^ state[index + 20];
            for (int index = 0; index < 5; ++index)
            {
                ulong delta = lanes[(index + 4) % 5] ^ BitOperations.RotateLeft(lanes[(index + 1) % 5], 1);
                for (int row = 0; row < 25; row += 5) state[row + index] ^= delta;
            }
            ulong carry = state[1];
            for (int index = 0; index < 24; ++index)
            {
                int lane = PiLane[index];
                ulong saved = state[lane];
                state[lane] = BitOperations.RotateLeft(carry, RotationOffsets[index]); carry = saved;
            }
            for (int row = 0; row < 25; row += 5)
            {
                Array.Copy(state, row, lanes, 0, 5);
                for (int index = 0; index < 5; ++index) state[row + index] ^= ~lanes[(index + 1) % 5] & lanes[(index + 2) % 5];
            }
            state[0] ^= round;
        }
    }
}
