using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;

namespace CastMic;

/// iPhone のカメラ映像 (JPEG) を仮想カメラ「CastMic Camera」に流す。
/// 仮想カメラ本体は CastMicCam.dll (Frame Server 内で動くメディアソース)。ここでは登録と共有メモリへの書き込みだけ行う。
public sealed class VirtualCamera : IDisposable
{
    const int W = 1280, H = 720, HeaderSize = 64, Nv12Size = W * H * 3 / 2;
    const string GlobalName = @"Global\CastMicCamFrame", LocalName = @"Local\CastMicCamFrame";

    readonly Bitmap _canvas = new(W, H, PixelFormat.Format32bppArgb);
    readonly byte[] _nv12 = new byte[Nv12Size];
    readonly object _lock = new();
    MemoryMappedFile? _map;
    MemoryMappedViewAccessor? _view;
    DateTime _nextOpenTry;
    bool _started;

    public string? Error { get; private set; }

    /// Windows 11 (22000+) のみ対応
    public bool Start()
    {
        if (Environment.OSVersion.Version.Build < 22000) { Error = "仮想カメラは Windows 11 以降が必要です。"; return false; }
        try
        {
            var hr = CastMicCam_Start();
            if (hr < 0) { Error = $"仮想カメラを登録できませんでした (0x{hr:X8})。インストーラーで CastMic を入れ直してください。"; return false; }
        }
        catch (DllNotFoundException) { Error = "CastMicCam.dll が見つかりません。"; return false; }
        _started = true;
        return true;
    }

    byte[]? _latest;
    readonly AutoResetEvent _signal = new(false);
    Thread? _worker;
    volatile bool _disposed;

    /// 受信スレッドから呼ばれる。デコードは別スレッドで最新フレームだけ行う (音声の受信を止めないため)
    public void PushJpeg(byte[] jpeg)
    {
        if (_disposed) return;
        Interlocked.Exchange(ref _latest, jpeg);
        if (_worker == null)
        {
            lock (_lock)
            {
                _worker ??= new Thread(Worker) { IsBackground = true, Name = "virtual-camera" };
                if (!_worker.IsAlive) _worker.Start();
            }
        }
        _signal.Set();
    }

    void Worker()
    {
        while (!_disposed)
        {
            _signal.WaitOne(1000);
            var jpeg = Interlocked.Exchange(ref _latest, null);
            if (jpeg != null) Process(jpeg);
        }
    }

    void Process(byte[] jpeg)
    {
        lock (_lock)
        {
            if (!EnsureMapped()) return;
            try
            {
                using var ms = new MemoryStream(jpeg);
                using var img = Image.FromStream(ms, false, false);
                using (var g = Graphics.FromImage(_canvas))
                {
                    g.InterpolationMode = InterpolationMode.Bilinear;
                    g.Clear(Color.Black);
                    // アスペクト比を保って中央に
                    var scale = Math.Min((float)W / img.Width, (float)H / img.Height);
                    int dw = (int)(img.Width * scale), dh = (int)(img.Height * scale);
                    g.DrawImage(img, (W - dw) / 2, (H - dh) / 2, dw, dh);
                }
                ToNv12();
                Write();
            }
            catch (ArgumentException) { /* 壊れた JPEG は捨てる */ }
            catch (ExternalException) { }
        }
    }

    bool EnsureMapped()
    {
        if (_view != null) return true;
        if (DateTime.Now < _nextOpenTry) return false;
        _nextOpenTry = DateTime.Now.AddSeconds(1);
        // 共有メモリはカメラが使われている間だけ Frame Server 側が作る
        foreach (var name in new[] { GlobalName, LocalName })
        {
            try
            {
                _map = MemoryMappedFile.OpenExisting(name, MemoryMappedFileRights.ReadWrite);
                _view = _map.CreateViewAccessor(0, HeaderSize + Nv12Size, MemoryMappedFileAccess.ReadWrite);
                return true;
            }
            catch (FileNotFoundException) { }
            catch (UnauthorizedAccessException) { }
        }
        return false;
    }

    unsafe void ToNv12()
    {
        var data = _canvas.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            byte* src = (byte*)data.Scan0;
            int stride = data.Stride;
            fixed (byte* dst = _nv12)
            {
                byte* uv = dst + W * H;
                for (int y = 0; y < H; y++)
                {
                    byte* row = src + y * stride;
                    byte* yRow = dst + y * W;
                    for (int x = 0; x < W; x++)
                    {
                        int b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2];
                        yRow[x] = (byte)(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
                        if ((y & 1) == 0 && (x & 1) == 0)
                        {
                            byte* o = uv + (y / 2) * W + x;
                            o[0] = (byte)(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
                            o[1] = (byte)(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
                        }
                    }
                }
            }
        }
        finally { _canvas.UnlockBits(data); }
    }

    unsafe void Write()
    {
        byte* p = null;
        var handle = _view!.SafeMemoryMappedViewHandle;
        handle.AcquirePointer(ref p);
        try
        {
            p += _view.PointerOffset;
            int* seq = (int*)p;
            Interlocked.Increment(ref *seq);              // 奇数 = 書き込み中
            *(uint*)(p + 4) = W;
            *(uint*)(p + 8) = H;
            Marshal.Copy(_nv12, 0, (IntPtr)(p + HeaderSize), Nv12Size);
            *(long*)(p + 16) = System.Diagnostics.Stopwatch.GetTimestamp();
            Interlocked.Increment(ref *seq);              // 偶数 = 完了
        }
        finally { handle.ReleasePointer(); }
    }

    public void Dispose()
    {
        _disposed = true;
        _signal.Set();
        _worker?.Join(1000);
        lock (_lock)
        {
            _view?.Dispose(); _map?.Dispose();
            _view = null; _map = null;
        }
        if (_started) { try { CastMicCam_Stop(); } catch (DllNotFoundException) { } }
        _canvas.Dispose();
    }

    [DllImport("CastMicCam.dll", ExactSpelling = true)] static extern int CastMicCam_Start();
    [DllImport("CastMicCam.dll", ExactSpelling = true)] static extern int CastMicCam_Stop();
}
