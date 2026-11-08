using System.Net;
using System.Net.Sockets;
using System.Text;

namespace CastMic;

/// TCP 48100 で送信側 (iPhone/Mac) を 1 台受け付ける
public sealed class CastServer : IDisposable
{
    public const int Port = 48100;
    readonly TcpListener _listener = new(IPAddress.Any, Port);
    readonly CancellationTokenSource _cts = new();
    readonly IAudioBridge _bridge;
    readonly object _sendLock = new();
    NetworkStream? _stream;

    public event Action<string>? Log;
    public event Action<string?>? ClientChanged;
    public event Action<string>? ClientHello;

    public CastServer(IAudioBridge bridge)
    {
        _bridge = bridge;
        _bridge.SpeakerData += pcm => Send(FrameType.SpeakerAudio, pcm);
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
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_cts.Token); }
            catch { return; }
            // 新しい接続が来たら古い接続を置き換える
            lock (_sendLock) { _stream?.Dispose(); }
            _ = Serve(client);
        }
    }

    async Task Serve(TcpClient client)
    {
        client.NoDelay = true;
        var ep = client.Client.RemoteEndPoint?.ToString() ?? "?";
        var stream = client.GetStream();
        lock (_sendLock) _stream = stream;
        Log?.Invoke($"接続: {ep}");
        ClientChanged?.Invoke(ep);
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                var (type, payload) = await Frame.ReadAsync(stream, _cts.Token);
                switch (type)
                {
                    case FrameType.MicAudio: _bridge.WriteMic(payload); break;
                    case FrameType.Hello:
                        var name = Encoding.UTF8.GetString(payload);
                        Log?.Invoke($"Hello: {name}");
                        ClientHello?.Invoke(name);
                        Send(FrameType.Hello, Encoding.UTF8.GetBytes($"{{\"name\":\"{Environment.MachineName}\",\"version\":1}}"));
                        break;
                    case FrameType.Ping: Send(FrameType.Ping, payload); break;
                }
            }
        }
        catch (Exception ex) when (ex is IOException or EndOfStreamException or OperationCanceledException or InvalidDataException or ObjectDisposedException)
        {
            Log?.Invoke($"切断: {ep} ({ex.Message})");
        }
        finally
        {
            lock (_sendLock) { if (_stream == stream) { _stream = null; ClientChanged?.Invoke(null); } }
            client.Dispose();
        }
    }

    void Send(FrameType type, byte[] payload)
    {
        lock (_sendLock)
        {
            if (_stream == null) return;
            try { _stream.Write(Frame.Encode(type, payload)); }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException) { _stream = null; }
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener.Stop();
        lock (_sendLock) _stream?.Dispose();
    }
}
