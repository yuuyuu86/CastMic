using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CastMic;

/// 自作仮想オーディオドライバ (driver/) との IOCTL ブリッジ。定義は driver/inc/CastMicIoctl.h と一致させること
public sealed class DriverBridge : IAudioBridge
{
    const string DevicePath = @"\\.\CastMicAudio";
    const uint FILE_DEVICE_UNKNOWN = 0x22, METHOD_BUFFERED = 0, FILE_READ_ACCESS = 1, FILE_WRITE_ACCESS = 2;
    static uint Ctl(uint fn, uint access) => (FILE_DEVICE_UNKNOWN << 16) | (access << 14) | (fn << 2) | METHOD_BUFFERED;
    static readonly uint IOCTL_WRITE_MIC = Ctl(0x800, FILE_WRITE_ACCESS);
    static readonly uint IOCTL_READ_SPEAKER = Ctl(0x801, FILE_READ_ACCESS);

    readonly SafeFileHandle _h;
    readonly CancellationTokenSource _cts = new();
    Thread? _reader;

    public string Name => "CastMic ドライバ";
    public event Action<byte[]>? SpeakerData;
    public event Action<string>? Error;
    /// ドライバ側のリングバッファ (200ms) が上限を持つのでここでは使わない
    public int MicBufferMs { get; set; } = 80;

    DriverBridge(SafeFileHandle h) => _h = h;

    public static DriverBridge? TryOpen()
    {
        var h = CreateFile(DevicePath, 0xC0000000 /*RW*/, 0, IntPtr.Zero, 3 /*OPEN_EXISTING*/, 0, IntPtr.Zero);
        if (h.IsInvalid) { h.Dispose(); return null; }
        return new DriverBridge(h);
    }

    public void Start()
    {
        _reader = new Thread(ReadLoop) { IsBackground = true, Name = "driver-speaker", Priority = ThreadPriority.Highest };
        _reader.Start();
    }

    public unsafe void WriteMic(byte[] pcm)
    {
        if (_cts.IsCancellationRequested) return;
        fixed (byte* p = pcm)
            DeviceIoControl(_h, IOCTL_WRITE_MIC, (IntPtr)p, pcm.Length, IntPtr.Zero, 0, out _, IntPtr.Zero);
    }

    unsafe void ReadLoop()
    {
        var buf = new byte[1920]; // 10ms stereo
        while (!_cts.IsCancellationRequested)
        {
            int got;
            fixed (byte* p = buf)
            {
                // ノンブロッキング: 溜まっている分だけ返る
                if (!DeviceIoControl(_h, IOCTL_READ_SPEAKER, IntPtr.Zero, 0, (IntPtr)p, buf.Length, out got, IntPtr.Zero))
                {
                    // バックグラウンドスレッドで例外を投げるとアプリごと落ちるので、ログに出して終了
                    if (!_cts.IsCancellationRequested) Error?.Invoke($"ドライバ読み出し失敗: {new Win32Exception().Message}");
                    return;
                }
            }
            if (got > 0) SpeakerData?.Invoke(buf.AsSpan(0, got).ToArray());
            else Thread.Sleep(2);
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        CancelIoEx(_h, IntPtr.Zero);
        _reader?.Join(1000); // 読み出しスレッドが閉じたハンドルを使わないよう待つ
        _h.Dispose();
    }

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, out int returned, IntPtr ov);
    [DllImport("kernel32", SetLastError = true)]
    static extern bool CancelIoEx(SafeFileHandle h, IntPtr ov);
}
