using System.Net.Sockets;
using System.Text;

namespace CastMic;

/// 中継 Mac (CastMic の「中継」機能) に、iPhone / Mac からの接続を待つための接続を常に張っておく。
///
/// 手順:
///   1. PC → 中継: "CMRH <room>\n" (room = 証明書指紋の先頭 32 桁) を送って待つ
///   2. 端末が中継に TLS で接続すると、中継は TLS の宛先名 (SNI = "r<room>.castmic.invalid") で部屋を探し、
///      PC に 0x01 を 1 バイト送ってから両方のバイト列をそのまま流す
///   3. PC は 0x01 を受け取ったら、その接続で通常どおり TLS サーバーとして振る舞う
/// 中継は暗号化された中身を見られない。なりすました PC は証明書の指紋が合わないので端末側で弾かれる。
public sealed class RelayConnector : IDisposable
{
    public const int DefaultPort = 48101;
    const int Idle = 2;   // 同時に待たせておく接続数 (= 同時に受けられる新規接続数)

    readonly string _host;
    readonly int _port;
    readonly string _room;
    readonly CastServer _server;
    readonly CancellationTokenSource _cts = new();
    string? _lastError;

    public event Action<string>? Log;

    public RelayConnector(string host, int port, string room, CastServer server)
    {
        _host = host; _port = port; _room = room; _server = server;
    }

    public static string RoomFor(string fingerprintHex) => fingerprintHex[..32].ToLowerInvariant();

    public static bool TryParse(string? s, out string host, out int port)
    {
        host = ""; port = DefaultPort;
        if (string.IsNullOrWhiteSpace(s)) return false;
        s = s.Trim();
        var i = s.LastIndexOf(':');
        if (i > 0 && int.TryParse(s[(i + 1)..], out var p) && p is > 0 and < 65536) { host = s[..i]; port = p; }
        else host = s;
        return Uri.CheckHostName(host) != UriHostNameType.Unknown;
    }

    public void Start()
    {
        for (int i = 0; i < Idle; i++) _ = Loop();
    }

    async Task Loop()
    {
        var delay = TimeSpan.FromSeconds(1);
        while (!_cts.IsCancellationRequested)
        {
            TcpClient? tcp = null;
            try
            {
                tcp = new TcpClient { NoDelay = true };
                await tcp.ConnectAsync(_host, _port, _cts.Token);
                tcp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
                var stream = tcp.GetStream();
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"CMRH {_room}\n"), _cts.Token);
                if (_lastError != null) { Log?.Invoke("中継 Mac に再接続しました。"); _lastError = null; }
                delay = TimeSpan.FromSeconds(1);

                // 端末が来るまで待つ (中継が 0x01 を送ってくる)
                var one = new byte[1];
                int n = await stream.ReadAsync(one, _cts.Token);
                if (n != 1 || one[0] != 0x01) throw new IOException("中継との接続が切れました");

                _server.ServeRelayed(tcp, stream, $"中継経由 {_host}");
                tcp = null; // 所有権を CastServer へ
            }
            catch (OperationCanceledException) { tcp?.Dispose(); return; }
            catch (Exception ex) when (ex is SocketException or IOException)
            {
                tcp?.Dispose();
                if (_lastError != ex.Message) { Log?.Invoke($"中継 Mac に接続できません: {ex.Message}"); _lastError = ex.Message; }
                try { await Task.Delay(delay, _cts.Token); } catch (OperationCanceledException) { return; }
                delay = TimeSpan.FromSeconds(Math.Min(30, delay.TotalSeconds * 2));
            }
        }
    }

    public void Dispose() => _cts.Cancel();
}
