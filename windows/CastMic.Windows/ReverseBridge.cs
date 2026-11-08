using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace CastMic;

/// 逆方向モード (Mac が Windows のマイク / スピーカーを使う) 用:
///  - Windows の既定のマイクを録音して送る (48k stereo s16)
///  - Mac から届いた音 (48k stereo s16) を既定のスピーカーで鳴らす
public sealed class ReverseBridge : IAudioBridge
{
    readonly BufferedWaveProvider _play = new(new WaveFormat(Frame.SampleRate, 16, 2))
    {
        BufferDuration = TimeSpan.FromMilliseconds(500),
        DiscardOnBufferOverflow = true,
    };
    readonly WasapiOut _out;
    readonly WasapiCapture _cap;
    BufferedWaveProvider? _capBuf;
    IWaveProvider? _capConv;
    readonly byte[] _convBuf = new byte[1920 * 4];

    public string Name => "Windows の既定のマイク / スピーカー";
    public event Action<byte[]>? SpeakerData;
    public int MicBufferMs { get; set; } = 80;

    public ReverseBridge()
    {
        _out = new WasapiOut(AudioClientShareMode.Shared, true, 20);
        _out.Init(_play);
        _cap = new WasapiCapture { ShareMode = AudioClientShareMode.Shared };
        _cap.DataAvailable += OnCapture;
    }

    public void Start()
    {
        _capBuf = new BufferedWaveProvider(_cap.WaveFormat) { BufferDuration = TimeSpan.FromMilliseconds(500), DiscardOnBufferOverflow = true, ReadFully = false };
        ISampleProvider sp = _capBuf.ToSampleProvider();
        if (sp.WaveFormat.Channels == 1) sp = new MonoToStereoSampleProvider(sp);
        else if (sp.WaveFormat.Channels > 2) sp = new MultiplexingSampleProvider(new[] { sp }, 2);
        if (sp.WaveFormat.SampleRate != Frame.SampleRate) sp = new WdlResamplingSampleProvider(sp, Frame.SampleRate);
        _capConv = sp.ToWaveProvider16();
        _out.Play();
        _cap.StartRecording();
    }

    void OnCapture(object? s, WaveInEventArgs e)
    {
        if (_capBuf == null || _capConv == null || e.BytesRecorded == 0) return;
        _capBuf.AddSamples(e.Buffer, 0, e.BytesRecorded);
        int n;
        while ((n = _capConv.Read(_convBuf, 0, 1920)) > 0)
            SpeakerData?.Invoke(_convBuf.AsSpan(0, n).ToArray());
    }

    /// Mac から届いた音 (stereo)
    public void WriteMic(byte[] pcm)
    {
        if (_play.BufferedDuration.TotalMilliseconds > MicBufferMs) _play.ClearBuffer();
        _play.AddSamples(pcm, 0, pcm.Length - pcm.Length % 4);
    }

    public void Dispose()
    {
        _cap.StopRecording(); _cap.Dispose();
        _out.Stop(); _out.Dispose();
    }
}
