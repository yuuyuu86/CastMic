using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace CastMic;

public sealed class MainForm : Form
{
    readonly Label _status = new() { Dock = DockStyle.Top, Height = 28, Padding = new Padding(8, 6, 8, 0) };
    readonly Label _ips = new() { Dock = DockStyle.Top, Height = 90, Padding = new Padding(8, 4, 8, 0) };
    readonly TextBox _log = new() { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
    IAudioBridge? _bridge;
    CastServer? _server;

    public MainForm()
    {
        Text = "CastMic";
        Width = 460; Height = 380;
        Controls.Add(_log);
        Controls.Add(_ips);
        Controls.Add(_status);
        Load += (_, _) => StartAll();
        FormClosed += (_, _) => { _server?.Dispose(); _bridge?.Dispose(); };
    }

    void StartAll()
    {
        _ips.Text = "iPhone / Mac にこのアドレスを入力:\r\n" + string.Join("\r\n", LocalAddresses().Select(a => $"  {a}"));
        _bridge = (IAudioBridge?)DriverBridge.TryOpen() ?? CableBridge.TryCreate();
        if (_bridge == null)
        {
            _status.Text = "オーディオデバイスが見つかりません";
            AppendLog("CastMic ドライバも VB-CABLE も見つかりません。どちらかをインストールしてください。");
            return;
        }
        AppendLog($"オーディオ: {_bridge.Name}");
        _bridge.Start();
        _server = new CastServer(_bridge);
        _server.Log += AppendLog;
        _server.ClientChanged += c => Ui(() => _status.Text = c == null ? $"待機中 (TCP {CastServer.Port})" : $"接続中: {c}");
        _server.Start();
        _status.Text = $"待機中 (TCP {CastServer.Port})";
    }

    static IEnumerable<string> LocalAddresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses
                .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                .Select(a => $"{a.Address}  ({n.Name})"));

    void AppendLog(string s) => Ui(() => _log.AppendText($"[{DateTime.Now:HH:mm:ss}] {s}\r\n"));
    void Ui(Action a) { if (IsHandleCreated) BeginInvoke(a); }
}
