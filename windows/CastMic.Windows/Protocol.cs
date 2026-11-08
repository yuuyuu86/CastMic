using System.Buffers.Binary;

namespace CastMic;

/// docs/PROTOCOL.md 参照
public enum FrameType : byte
{
    Hello = 1,
    MicAudio = 2,      // PCM s16le 48k mono
    SpeakerAudio = 3,  // PCM s16le 48k stereo
    Ping = 4,
    AuthFailed = 5,
    MicOpus = 6,       // Opus 1 パケット (20ms, mono)
    SpeakerOpus = 7,   // Opus 1 パケット (20ms, stereo)
    MuteState = 8,     // u8: 1 = ミュート
    Roles = 9,         // JSON {"mic":bool,"speaker":bool,"camera":bool}
    VideoJpeg = 10,    // カメラ映像 1 フレーム (JPEG)
}

public static class Frame
{
    public const int HeaderSize = 8;
    public const int SampleRate = 48000;
    public const int OpusFrame = 960; // 20ms
    public const int MaxPayload = 64 * 1024;
    public const int MaxHelloPayload = 1024;
    public const int MaxVideoPayload = 1 << 20;

    public static byte[] Encode(FrameType type, ReadOnlySpan<byte> payload)
    {
        var buf = new byte[HeaderSize + payload.Length];
        buf[0] = 0x43; buf[1] = 0x4D; buf[2] = (byte)type; buf[3] = 0;
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(4), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(HeaderSize));
        return buf;
    }

    public static async Task<(FrameType type, byte[] payload)> ReadAsync(Stream s, CancellationToken ct, int maxPayload)
    {
        var header = new byte[HeaderSize];
        await s.ReadExactlyAsync(header, ct);
        if (header[0] != 0x43 || header[1] != 0x4D) throw new InvalidDataException("bad magic");
        var len = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
        if (len > (header[2] == (byte)FrameType.VideoJpeg ? Math.Max(maxPayload, MaxVideoPayload) : maxPayload)) throw new InvalidDataException("frame too large");
        var payload = new byte[len];
        await s.ReadExactlyAsync(payload, ct);
        return ((FrameType)header[2], payload);
    }
}
