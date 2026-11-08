using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace CastMic;

/// ドライバ完成までのフォールバック:
///  マイク: VB-CABLE 等の仮想ケーブルの再生側 ("CABLE Input") へ書き込む → 録音側 "CABLE Output" がマイクとして見える
///  スピーカー: 既定の再生デバイスをループバック録音して送る
public sealed class CableBridge : IAudioBridge
{
    readonly BufferedWaveProvider _mic = new(new WaveFormat(Frame.SampleRate, 16, 1))
    {
        BufferDuration = TimeSpan.FromMilliseconds(200),
        DiscardOnBufferOverflow = true,
    };
    readonly WasapiOut _out;
    readonly WasapiLoopbackCapture _loop;
    BufferedWaveProvider? _loopBuf;
    IWaveProvider? _loopConv;
    readonly byte[] _convBuf = new byte[1920 * 4];

    public string Name { get; }
    public event Action<byte[]>? SpeakerData;

    CableBridge(MMDevice cable)
    {
        Name = $"仮想ケーブル ({cable.FriendlyName})";
        _out = new WasapiOut(cable, AudioClientShareMode.Shared, true, 20);
        _out.Init(new MonoToStereoSampleProvider(_mic.ToSampleProvider()));
        _loop = new WasapiLoopbackCapture();
        _loop.DataAvailable += OnLoopback;
    }

    public static CableBridge? TryCreate()
    {
        using var en = new MMDeviceEnumerator();
        var cable = en.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
            .FirstOrDefault(d => d.FriendlyName.Contains("CABLE Input", StringComparison.OrdinalIgnoreCase));
        if (cable == null) return null;
        // 既定の再生デバイスが CABLE Input だとマイク音声をループバックで拾って送り返してしまう
        using var def = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        if (def.ID == cable.ID) throw new InvalidOperationException("既定の再生デバイスが CABLE Input になっています。サウンド設定で別のスピーカーを既定にしてください。");
        return new CableBridge(cable);
    }

    public void Start()
    {
        var fmt = _loop.WaveFormat;
        _loopBuf = new BufferedWaveProvider(fmt) { BufferDuration = TimeSpan.FromMilliseconds(500), DiscardOnBufferOverflow = true, ReadFully = false };
        ISampleProvider sp = _loopBuf.ToSampleProvider();
        if (sp.WaveFormat.Channels == 1) sp = new MonoToStereoSampleProvider(sp);
        else if (sp.WaveFormat.Channels > 2) sp = new MultiplexingSampleProvider(new[] { sp }, 2);
        if (sp.WaveFormat.SampleRate != Frame.SampleRate) sp = new WdlResamplingSampleProvider(sp, Frame.SampleRate);
        _loopConv = sp.ToWaveProvider16();
        _out.Play();
        _loop.StartRecording();
    }

    void OnLoopback(object? s, WaveInEventArgs e)
    {
        if (_loopBuf == null || _loopConv == null || e.BytesRecorded == 0) return;
        _loopBuf.AddSamples(e.Buffer, 0, e.BytesRecorded);
        int n;
        while ((n = _loopConv.Read(_convBuf, 0, 1920)) > 0)
            SpeakerData?.Invoke(_convBuf.AsSpan(0, n).ToArray());
    }

    public int MicBufferMs { get; set; } = 80;

    public void WriteMic(byte[] pcm)
    {
        if (_mic.BufferedDuration.TotalMilliseconds > MicBufferMs) _mic.ClearBuffer();
        _mic.AddSamples(pcm, 0, pcm.Length);
    }

    public void Dispose()
    {
        _loop.StopRecording(); _loop.Dispose();
        _out.Stop(); _out.Dispose();
    }
}
