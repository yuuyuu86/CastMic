using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Threading.Channels;
using Concentus;
using Concentus.Enums;

namespace CastMic;

/// TCP 48100 で送信側 (iPhone/Mac) を受け付ける。複数台の同時接続に対応。
/// - 通信は TLS (自己署名証明書) で暗号化
/// - ペアリングコード付きの Hello を受け取るまで音声は一切やり取りしない
/// - マイク: mic 役の端末のうち最後に接続/指定したもの 1 台だけを使う
/// - スピーカー: speaker 役の全端末へ送る
public sealed class CastServer : IDisposable
{
    public const int Port = 48100;
    const int MaxPending = 4;
    const int MaxClients = 4;
    static readonly TimeSpan HelloTimeout = TimeSpan.FromSeconds(5);
    static readonly TimeSpan FailDelay = TimeSpan.FromSeconds(1);

    readonly TcpListener _listener = new(IPAddress.Any, Port);
    readonly CancellationTokenSource _cts = new();
    readonly IAudioBridge _bridge;
    readonly X509Certificate2 _cert;
    readonly Func<IAudioBridge> _reverseFactory;
    IAudioBridge? _reverse;
    readonly object _lock = new();
    readonly List<Client> _clients = new();
    Client? _micOwner;
    int _pending;
    volatile bool _muted;

    public string PairingCode { get; set; }
    public event Action<string>? Log;
    /// 接続中の端末一覧 (表示用)
    public event Action<IReadOnlyList<string>>? ClientsChanged;
    public event Action<string>? ClientHello;
    public event Action<bool>? MuteChanged;

    sealed class Client(TcpClient tcp, string endpoint)
    {
        public readonly TcpClient Tcp = tcp;
        public readonly string Endpoint = endpoint;
        public readonly Channel<byte[]> Out = Channel.CreateBounded<byte[]>(
            new BoundedChannelOptions(32) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
        public readonly CancellationTokenSource Cts = new();
        public string Name = "?";
        public bool Opus;
        /// 逆方向 (Mac が Windows のマイク / スピーカーを使う)
        public bool Reverse;
        public int UpChannels = 1;
        public volatile bool WantsMic = true, WantsSpeaker = true;
        public IOpusDecoder? MicDecoder;
        public IOpusEncoder? SpeakerEncoder;
        public readonly short[] SpkAcc = new short[Frame.OpusFrame * 2];
        public int SpkAccCount;
        public readonly object SpkLock = new();
        public string Label => Reverse
            ? $"{Name} (逆方向: Windows のマイク/スピーカーを使用)"
            : $"{Name} ({(WantsMic ? "マイク" : "")}{(WantsMic && WantsSpeaker ? "+" : "")}{(WantsSpeaker ? "スピーカー" : "")})";
    }

    public CastServer(IAudioBridge bridge, string pairingCode, X509Certificate2 cert, Func<IAudioBridge>? reverseFactory = null)
    {
        _bridge = bridge;
        _cert = cert;
        PairingCode = pairingCode;
        _reverseFactory = reverseFactory ?? (() => new ReverseBridge());
        _bridge.SpeakerData += pcm => OnSpeaker(pcm, reverse: false);
    }

    /// 最初の逆方向クライアントが来たときに Windows の実デバイスを開く
    IAudioBridge? ReverseBridgeOrNull()
    {
        lock (_lock)
        {
            if (_reverse != null) return _reverse;
            try
            {
                var r = _reverseFactory();
                r.SpeakerData += pcm => OnSpeaker(pcm, reverse: true);
                r.Start();
                _reverse = r;
                Log?.Invoke($"逆方向オーディオ: {r.Name}");
            }
            catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException)
            {
                Log?.Invoke($"Windows のマイク / スピーカーを開けませんでした: {ex.Message}");
            }
            return _reverse;
        }
    }

    public bool Muted
    {
        get => _muted;
        set
        {
            if (_muted == value) return;
            _muted = value;
            Client[] all;
            lock (_lock) all = _clients.ToArray();
            foreach (var c in all) Enqueue(c, FrameType.MuteState, [(byte)(value ? 1 : 0)]);
            MuteChanged?.Invoke(value);
        }
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
        var stream = new SslStream(tcp.GetStream(), false);
        bool authed = false;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token, client.Cts.Token);
        var ct = linked.Token;
        try
        {
            // --- TLS + 認証 ---
            using (var helloCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                helloCts.CancelAfter(HelloTimeout);
                await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = _cert,
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    ClientCertificateRequired = false,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                }, helloCts.Token);

                var (type, payload) = await Frame.ReadAsync(stream, helloCts.Token, Frame.MaxHelloPayload);
                var hello = type == FrameType.Hello ? Hello.Parse(payload) : null;
                if (hello == null || !Pairing.Matches(PairingCode, hello.Code))
                {
                    Log?.Invoke($"ペアリングコード不一致のため拒否: {client.Endpoint}");
                    await Task.Delay(FailDelay, ct); // 総当たり対策
                    await stream.WriteAsync(Frame.Encode(FrameType.AuthFailed, ReadOnlySpan<byte>.Empty), ct);
                    return;
                }
                lock (_lock)
                {
                    if (_clients.Count >= MaxClients)
                    {
                        Log?.Invoke($"接続数の上限 ({MaxClients}) のため拒否: {hello.Name}");
                        return;
                    }
                    authed = true;
                    Interlocked.Decrement(ref _pending);
                    client.Name = hello.Name;
                    client.Opus = hello.Codec == "opus";
                    client.WantsMic = hello.Mic;
                    client.WantsSpeaker = hello.Speaker;
                    client.Reverse = hello.Reverse;
                    client.UpChannels = hello.Reverse ? 2 : 1;
                    if (client.Opus)
                    {
                        client.MicDecoder = OpusCodecFactory.CreateDecoder(Frame.SampleRate, client.UpChannels);
                        client.SpeakerEncoder = OpusCodecFactory.CreateEncoder(Frame.SampleRate, 2, OpusApplication.OPUS_APPLICATION_AUDIO);
                        client.SpeakerEncoder.Bitrate = 96_000;
                    }
                    _clients.Add(client);
                    if (client.WantsMic && !client.Reverse)
                    {
                        _micOwner = client;
                        _bridge.MicBufferMs = hello.BufferMs;
                    }
                }

                Log?.Invoke($"接続: {client.Name} ({client.Endpoint}, {(client.Opus ? "Opus" : "PCM")}{(client.Reverse ? ", 逆方向" : "")})");
                if (client.Reverse && ReverseBridgeOrNull() is { } rb) rb.MicBufferMs = hello.BufferMs;
                ClientHello?.Invoke(client.Name);
                RaiseClientsChanged();
                var reply = JsonSerializer.SerializeToUtf8Bytes(new
                {
                    name = Environment.MachineName,
                    version = 2,
                    codec = client.Opus ? "opus" : "pcm",
                    muted = _muted,
                });
                await stream.WriteAsync(Frame.Encode(FrameType.Hello, reply), ct);
            }

            var writer = WriteLoop(client, stream, ct);
            var pcm = new short[Frame.OpusFrame * 6];

            // --- 受信 ---
            while (!ct.IsCancellationRequested)
            {
                var (type, payload) = await Frame.ReadAsync(stream, ct, Frame.MaxPayload);
                switch (type)
                {
                    case FrameType.MicAudio when !client.Opus:
                        if (client.Reverse) { if (client.WantsMic) _reverse?.WriteMic(payload); }
                        else if (IsMicSource(client)) _bridge.WriteMic(payload);
                        break;
                    case FrameType.MicOpus when client.MicDecoder != null:
                        var sink = client.Reverse ? (client.WantsMic ? _reverse : null) : (IsMicSource(client) ? _bridge : null);
                        if (sink == null) break;
                        int n;
                        try { n = client.MicDecoder.Decode(payload, pcm, pcm.Length / client.UpChannels, false) * client.UpChannels; }
                        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or IndexOutOfRangeException) { break; }
                        if (n > 0)
                        {
                            var bytes = new byte[n * 2];
                            Buffer.BlockCopy(pcm, 0, bytes, 0, bytes.Length);
                            sink.WriteMic(bytes);
                        }
                        break;
                    case FrameType.Ping:
                        if (payload.Length == 8) Enqueue(client, FrameType.Ping, payload);
                        break;
                    case FrameType.MuteState:
                        if (payload.Length == 1) Muted = payload[0] != 0;
                        break;
                    case FrameType.Roles:
                        if (Hello.ParseRoles(payload) is var (mic, spk))
                        {
                            lock (_lock)
                            {
                                client.WantsMic = mic;
                                client.WantsSpeaker = spk;
                                if (mic && !client.Reverse) _micOwner = client;
                                else if (_micOwner == client) _micOwner = _clients.LastOrDefault(c => c.WantsMic && !c.Reverse);
                            }
                            RaiseClientsChanged();
                        }
                        break;
                }
            }
            await writer;
        }
        catch (Exception ex) when (ex is IOException or EndOfStreamException or OperationCanceledException
                                       or InvalidDataException or ObjectDisposedException or SocketException
                                       or AuthenticationException)
        {
            if (authed) Log?.Invoke($"切断: {client.Name} ({client.Endpoint})");
        }
        finally
        {
            if (!authed) Interlocked.Decrement(ref _pending);
            client.Out.Writer.TryComplete();
            bool removed;
            lock (_lock)
            {
                removed = _clients.Remove(client);
                if (_micOwner == client) _micOwner = _clients.LastOrDefault(c => c.WantsMic && !c.Reverse);
                // 逆方向クライアントがいなくなったら実デバイスを閉じる
                if (_reverse != null && !_clients.Any(c => c.Reverse)) { _reverse.Dispose(); _reverse = null; }
            }
            if (removed) RaiseClientsChanged();
            stream.Dispose();
            tcp.Dispose();
        }
    }

    bool IsMicSource(Client c) => !_muted && c.WantsMic && _micOwner == c;

    /// Windows の音 (48k stereo s16le) を speaker 役の端末へ。
    /// 通常: 仮想スピーカーの音 / 逆方向: Windows の実マイクの音
    void OnSpeaker(byte[] pcm, bool reverse)
    {
        Client[] targets;
        lock (_lock) targets = _clients.Where(c => c.WantsSpeaker && c.Reverse == reverse).ToArray();
        foreach (var c in targets)
        {
            if (c.SpeakerEncoder == null)
            {
                Enqueue(c, FrameType.SpeakerAudio, pcm);
                continue;
            }
            lock (c.SpkLock)
            {
                var samples = pcm.Length / 2;
                int offset = 0;
                while (offset < samples)
                {
                    int take = Math.Min(samples - offset, c.SpkAcc.Length - c.SpkAccCount);
                    Buffer.BlockCopy(pcm, offset * 2, c.SpkAcc, c.SpkAccCount * 2, take * 2);
                    c.SpkAccCount += take;
                    offset += take;
                    if (c.SpkAccCount == c.SpkAcc.Length)
                    {
                        var packet = new byte[1500];
                        int len = c.SpeakerEncoder.Encode(c.SpkAcc, Frame.OpusFrame, packet, packet.Length);
                        if (len > 0) Enqueue(c, FrameType.SpeakerOpus, packet.AsSpan(0, len).ToArray());
                        c.SpkAccCount = 0;
                    }
                }
            }
        }
    }

    static async Task WriteLoop(Client client, Stream stream, CancellationToken ct)
    {
        try
        {
            await foreach (var frame in client.Out.Reader.ReadAllAsync(ct))
                await stream.WriteAsync(frame, ct);
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException)
        {
            client.Cts.Cancel();
        }
    }

    void RaiseClientsChanged()
    {
        string[] labels;
        lock (_lock) labels = _clients.Select(c => (c == _micOwner ? "🎤 " : "") + c.Label).ToArray();
        ClientsChanged?.Invoke(labels);
    }

    static void Enqueue(Client c, FrameType type, byte[] payload) => c.Out.Writer.TryWrite(Frame.Encode(type, payload));

    /// コード変更時: 全端末を切断
    public void DisconnectAll()
    {
        Client[] all;
        lock (_lock) all = _clients.ToArray();
        foreach (var c in all) c.Cts.Cancel();
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener.Stop();
        lock (_lock) { _reverse?.Dispose(); _reverse = null; }
    }

    sealed record Hello(string Name, string? Code, string Codec, bool Mic, bool Speaker, int BufferMs, bool Reverse)
    {
        public static Hello? Parse(byte[] payload)
        {
            try
            {
                using var doc = JsonDocument.Parse(payload);
                var r = doc.RootElement;
                string? Str(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                bool Bool(string k, bool d) => r.TryGetProperty(k, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False ? v.GetBoolean() : d;
                int buf = r.TryGetProperty("bufferMs", out var b) && b.TryGetInt32(out var bi) ? Math.Clamp(bi, 20, 500) : 80;
                // ログや通知に出すので制御文字を除去して短くする
                var name = new string((Str("name") ?? "?").Where(ch => !char.IsControl(ch)).Take(64).ToArray());
                var codec = Str("codec") == "opus" ? "opus" : "pcm";
                return new Hello(name, Str("code"), codec, Bool("mic", true), Bool("speaker", true), buf, Str("mode") == "reverse");
            }
            catch (JsonException) { return null; }
        }

        public static (bool mic, bool speaker)? ParseRoles(byte[] payload)
        {
            try
            {
                using var doc = JsonDocument.Parse(payload);
                var r = doc.RootElement;
                return (r.GetProperty("mic").GetBoolean(), r.GetProperty("speaker").GetBoolean());
            }
            catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException) { return null; }
        }
    }
}
