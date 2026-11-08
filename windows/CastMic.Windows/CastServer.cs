using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading.Channels;

namespace CastMic;

/// TCP 48100 で送信側 (iPhone/Mac) を受け付ける。
/// ペアリングコード付きの Hello を受け取るまで音声は一切やり取りしない。
public sealed class CastServer : IDisposable
{
    public const int Port = 48100;
    const int MaxPending = 4;                         // 認証前の同時接続数
    static readonly TimeSpan HelloTimeout = TimeSpan.FromSeconds(5);
    static readonly TimeSpan FailDelay = TimeSpan.FromSeconds(1);

    readonly TcpListener _listener = new(IPAddress.Any, Port);
    readonly CancellationTokenSource _cts = new();
    readonly IAudioBridge _bridge;
    readonly object _lock = new();
    Client? _active;
    int _pending;

    public string PairingCode { get; set; }
    public event Action<string>? Log;
    public event Action<string?>? ClientChanged;
    public event Action<string>? ClientHello;

    /// 1 接続ぶんの送信キュー。音声スレッドをネットワーク書き込みでブロックしないよう、溢れたら捨てる
    sealed class Client(TcpClient tcp, string endpoint)
    {
        public readonly TcpClient Tcp = tcp;
        public readonly string Endpoint = endpoint;
        public readonly Channel<byte[]> Out = Channel.CreateBounded<byte[]>(
            new BoundedChannelOptions(32) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
        public readonly CancellationTokenSource Cts = new();
    }

    public CastServer(IAudioBridge bridge, string pairingCode)
    {
        _bridge = bridge;
        PairingCode = pairingCode;
        _bridge.SpeakerData += pcm => Enqueue(_active, FrameType.SpeakerAudio, pcm);
    }

    public void Start()
    {
        _listener.Start();
        _ = AcceptLoop();
    }

    async Task AcceptLoop()
    {
        while (!_cts.IsCancellationRequested)
        {
            TcpClient tcp;
            try { tcp = await _listener.AcceptTcpClientAsync(_cts.Token); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { continue; }

            if (Interlocked.Increment(ref _pending) > MaxPending)
            {
                Interlocked.Decrement(ref _pending);
                tcp.Dispose();
                continue;
            }
            _ = Serve(tcp);
        }
    }

    async Task Serve(TcpClient tcp)
    {
        tcp.NoDelay = true;
        var client = new Client(tcp, tcp.Client.RemoteEndPoint?.ToString() ?? "?");
        var stream = tcp.GetStream();
        bool authed = false;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token, client.Cts.Token);
        var ct = linked.Token;
        try
        {
            // --- 認証 ---
            using (var helloCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                helloCts.CancelAfter(HelloTimeout);
                var (type, payload) = await Frame.ReadAsync(stream, helloCts.Token, Frame.MaxHelloPayload);
                var (name, code) = type == FrameType.Hello ? ParseHello(payload) : ("?", null);
                if (!Pairing.Matches(PairingCode, code))
                {
                    Log?.Invoke($"ペアリングコード不一致のため拒否: {client.Endpoint}");
                    await Task.Delay(FailDelay, ct); // 総当たり対策
                    await stream.WriteAsync(Frame.Encode(FrameType.AuthFailed, ReadOnlySpan<byte>.Empty), ct);
                    return;
                }
                authed = true;
                Interlocked.Decrement(ref _pending);

                // 認証済みの新しい接続だけが既存の接続を置き換えられる
                Client? old;
                lock (_lock) { old = _active; _active = client; }
                old?.Cts.Cancel();

                Log?.Invoke($"接続: {name} ({client.Endpoint})");
                ClientChanged?.Invoke($"{name} ({client.Endpoint})");
                ClientHello?.Invoke(name);
                var reply = JsonSerializer.SerializeToUtf8Bytes(new { name = Environment.MachineName, version = 1 });
                await stream.WriteAsync(Frame.Encode(FrameType.Hello, reply), ct);
            }

            var writer = WriteLoop(client, stream, ct);

            // --- 受信 ---
            while (!ct.IsCancellationRequested)
            {
                var (type, payload) = await Frame.ReadAsync(stream, ct, Frame.MaxPayload);
                switch (type)
                {
                    case FrameType.MicAudio: _bridge.WriteMic(payload); break;
                    case FrameType.Ping: if (payload.Length == 8) Enqueue(client, FrameType.Ping, payload); break;
                }
            }
            await writer;
        }
        catch (Exception ex) when (ex is IOException or EndOfStreamException or OperationCanceledException
                                       or InvalidDataException or ObjectDisposedException or SocketException)
        {
            if (authed) Log?.Invoke($"切断: {client.Endpoint}");
        }
        finally
        {
            if (!authed) Interlocked.Decrement(ref _pending);
            client.Out.Writer.TryComplete();
            bool wasActive;
            lock (_lock) { wasActive = _active == client; if (wasActive) _active = null; }
            if (wasActive) ClientChanged?.Invoke(null);
            tcp.Dispose();
        }
    }

    static async Task WriteLoop(Client client, NetworkStream stream, CancellationToken ct)
    {
        try
        {
            await foreach (var frame in client.Out.Reader.ReadAllAsync(ct))
                await stream.WriteAsync(frame, ct);
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException)
        {
            client.Cts.Cancel(); // 受信側も止める
        }
    }

    static (string name, string? code) ParseHello(byte[] payload)
    {
        try
        {
            using var doc = JsonDocument.Parse(payload);
            var root = doc.RootElement;
            var name = root.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString()! : "?";
            var code = root.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String ? c.GetString() : null;
            // ログや通知に出すので制御文字を除去して短くする
            name = new string(name.Where(ch => !char.IsControl(ch)).Take(64).ToArray());
            return (name, code);
        }
        catch (JsonException) { return ("?", null); }
    }

    static void Enqueue(Client? client, FrameType type, byte[] payload) =>
        client?.Out.Writer.TryWrite(Frame.Encode(type, payload));

    /// コード変更時など: 現在の接続を切る
    public void DisconnectActive()
    {
        Client? c;
        lock (_lock) c = _active;
        c?.Cts.Cancel();
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener.Stop();
    }
}
