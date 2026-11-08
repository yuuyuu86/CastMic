using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CastMic;

/// 自作仮想オーディオドライバ (driver/) との IOCTL ブリッジ。定義は driver/inc/CastMicIoctl.h と一致させること
public sealed class DriverBridge : IAudioBridge
{
    const string DevicePath = @"\\.\CastMicAudio";
    const uint FILE_DEVICE_UNKNOWN = 0x22, METHOD_BUFFERED = 0, FILE_ANY_ACCESS = 0;
    static uint Ctl(uint fn) => (FILE_DEVICE_UNKNOWN << 16) | (FILE_ANY_ACCESS << 14) | (fn << 2) | METHOD_BUFFERED;
    static readonly uint IOCTL_WRITE_MIC = Ctl(0x800);
    static readonly uint IOCTL_READ_SPEAKER = Ctl(0x801);

    readonly SafeFileHandle _h;
    readonly CancellationTokenSource _cts = new();
    Thread? _reader;

    public string Name => "CastMic ドライバ";
    public event Action<byte[]>? SpeakerData;

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
                    if (_cts.IsCancellationRequested) return;
                    throw new Win32Exception();
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
        _h.Dispose();
    }

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, out int returned, IntPtr ov);
    [DllImport("kernel32", SetLastError = true)]
    static extern bool CancelIoEx(SafeFileHandle h, IntPtr ov);
}
