using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using Microsoft.Win32;

namespace CastMic;

public sealed class MainForm : Form
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    readonly Label _status = new() { Dock = DockStyle.Top, Height = 28, Padding = new Padding(8, 6, 8, 0) };
    readonly Label _ips = new() { Dock = DockStyle.Top, Height = 90, Padding = new Padding(8, 4, 8, 0) };
    readonly Panel _pairRow = new() { Dock = DockStyle.Top, Height = 40, Padding = new Padding(8, 4, 8, 4) };
    readonly Label _code = new() { Dock = DockStyle.Fill, Font = new Font(FontFamily.GenericMonospace, 14, FontStyle.Bold), TextAlign = ContentAlignment.MiddleLeft };
    readonly Label _fp = new() { Dock = DockStyle.Top, Height = 24, Padding = new Padding(8, 2, 8, 0) };
    readonly Button _regen = new() { Dock = DockStyle.Right, Width = 110, Text = "コードを再生成" };
    readonly CheckBox _autostart = new() { Dock = DockStyle.Top, Height = 28, Padding = new Padding(8, 0, 8, 0), Text = "Windows 起動時にバックグラウンドで開始" };
    readonly TextBox _log = new() { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
    readonly NotifyIcon _tray = new() { Icon = SystemIcons.Application, Text = "CastMic", Visible = true };
    readonly bool _startHidden = Environment.GetCommandLineArgs().Contains("--background");
    IAudioBridge? _bridge;
    CastServer? _server;
    MdnsAdvertiser? _mdns;
    bool _quitting;

    public MainForm()
    {
        Text = "CastMic";
        Width = 460; Height = 420;
        Controls.Add(_log);
        Controls.Add(_autostart);
        Controls.Add(_fp);
        Controls.Add(_pairRow);
        _pairRow.Controls.Add(_code);
        _pairRow.Controls.Add(_regen);
        Controls.Add(_ips);
        Controls.Add(_status);

        var menu = new ContextMenuStrip();
        menu.Items.Add("開く", null, (_, _) => ShowWindow());
        menu.Items.Add("終了", null, (_, _) => { _quitting = true; Close(); });
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => ShowWindow();

        _autostart.Checked = Registry.CurrentUser.OpenSubKey(RunKey)?.GetValue("CastMic") != null;
        _autostart.CheckedChanged += (_, _) => SetAutostart(_autostart.Checked);

        _regen.Click += (_, _) =>
        {
            var code = Pairing.Regenerate();
            ShowCode(code);
            if (_server != null) { _server.PairingCode = code; _server.DisconnectActive(); }
            AppendLog("ペアリングコードを再生成しました。接続中の端末は切断されました。");
        };

        Load += (_, _) => StartAll();
        Shown += (_, _) => { if (_startHidden) Hide(); };
        // × ボタンはトレイへ格納 (終了はトレイメニューから)
        FormClosing += (_, e) =>
        {
            if (!_quitting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        };
        FormClosed += (_, _) => { _tray.Visible = false; _mdns?.Dispose(); _server?.Dispose(); _bridge?.Dispose(); };
    }

    void ShowWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }

    static void SetAutostart(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) key.SetValue("CastMic", $"\"{Environment.ProcessPath}\" --background");
        else key.DeleteValue("CastMic", false);
    }

    void ShowCode(string code) => _code.Text = $"ペアリングコード: {code[..3]} {code[3..]}";

    void StartAll()
    {
        var code = Pairing.Load();
        ShowCode(code);
        _ips.Text = "iPhone / Mac にこのアドレスを入力 (同じネットワークなら自動で表示されます):\r\n"
            + string.Join("\r\n", LocalAddresses().Select(a => $"  {a}"));
        try { _bridge = (IAudioBridge?)DriverBridge.TryOpen() ?? CableBridge.TryCreate(); }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            _status.Text = "オーディオの初期化に失敗しました";
            AppendLog(ex.Message);
            ShowWindow();
            return;
        }
        if (_bridge == null)
        {
            _status.Text = "オーディオデバイスが見つかりません";
            AppendLog("CastMic ドライバも VB-CABLE も見つかりません。どちらかをインストールしてください。");
            ShowWindow();
            return;
        }
        AppendLog($"オーディオ: {_bridge.Name}");
        if (_bridge is DriverBridge db) db.Error += AppendLog;
        _bridge.Start();
        System.Security.Cryptography.X509Certificates.X509Certificate2 cert;
        try { cert = ServerIdentity.LoadOrCreate(); }
        catch (System.Security.Cryptography.CryptographicException ex)
        {
            _status.Text = "証明書の作成に失敗しました";
            AppendLog(ex.Message);
            ShowWindow();
            return;
        }
        _fp.Text = $"確認コード (初回接続時に iPhone/Mac の表示と一致するか確認): {ServerIdentity.ShortFingerprint(ServerIdentity.Fingerprint(cert))}";
        _server = new CastServer(_bridge, code, cert);
        _server.Log += AppendLog;
        _server.ClientHello += json => Notify($"{ParseName(json)} が接続しました");
        _server.ClientChanged += c => Ui(() =>
        {
            _status.Text = c == null ? $"待機中 (TCP {CastServer.Port})" : $"接続中: {c}";
            _tray.Text = c == null ? "CastMic - 待機中" : "CastMic - 接続中";
        });
        _server.Start();
        _status.Text = $"待機中 (TCP {CastServer.Port})";

        _mdns = new MdnsAdvertiser();
        AppendLog(_mdns.Start(CastServer.Port) ? $"自動検出を有効化: {Environment.MachineName}" : "自動検出 (mDNS) を開始できませんでした。IP で接続してください。");
    }

    static string ParseName(string json)
    {
        try { return JsonDocument.Parse(json).RootElement.GetProperty("name").GetString() ?? "デバイス"; }
        catch { return "デバイス"; }
    }

    void Notify(string text) => Ui(() => _tray.ShowBalloonTip(2000, "CastMic", text, ToolTipIcon.Info));

    static IEnumerable<string> LocalAddresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses
                .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                .Select(a => $"{a.Address}  ({n.Name})"));

    void AppendLog(string s) => Ui(() => _log.AppendText($"[{DateTime.Now:HH:mm:ss}] {s}\r\n"));
    void Ui(Action a) { if (IsHandleCreated) BeginInvoke(a); }
}
