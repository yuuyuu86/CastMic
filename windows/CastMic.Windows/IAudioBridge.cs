namespace CastMic;

/// 受信したマイク音声を Windows の入力デバイスへ、Windows の出力音声を送信側へ渡す橋渡し
public interface IAudioBridge : IDisposable
{
    string Name { get; }
    /// 48kHz mono s16le
    void WriteMic(byte[] pcm);
    /// 48kHz stereo s16le
    event Action<byte[]>? SpeakerData;
    void Start();
}
