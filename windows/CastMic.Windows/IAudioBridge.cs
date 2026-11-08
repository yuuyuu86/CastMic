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
    /// マイク側の遅延上限 (ms)。これを超えて溜まったら古い分を捨てる
    int MicBufferMs { get; set; }
}
