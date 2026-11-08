using System.Buffers.Binary;

namespace CastMic;

/// docs/PROTOCOL.md 参照
public enum FrameType : byte { Hello = 1, MicAudio = 2, SpeakerAudio = 3, Ping = 4 }

public static class Frame
{
    public const int HeaderSize = 8;
    public const int SampleRate = 48000;
    public const int MaxPayload = 1 << 20;

    public static byte[] Encode(FrameType type, ReadOnlySpan<byte> payload)
    {
        var buf = new byte[HeaderSize + payload.Length];
        buf[0] = 0x43; buf[1] = 0x4D; buf[2] = (byte)type; buf[3] = 0;
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(4), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(HeaderSize));
        return buf;
    }

    public static async Task<(FrameType type, byte[] payload)> ReadAsync(Stream s, CancellationToken ct)
    {
        var header = new byte[HeaderSize];
        await s.ReadExactlyAsync(header, ct);
        if (header[0] != 0x43 || header[1] != 0x4D) throw new InvalidDataException("bad magic");
        var len = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
        if (len > MaxPayload) throw new InvalidDataException("frame too large");
        var payload = new byte[len];
        await s.ReadExactlyAsync(payload, ct);
        return ((FrameType)header[2], payload);
    }
}
