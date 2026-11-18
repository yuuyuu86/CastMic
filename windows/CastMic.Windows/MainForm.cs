using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Win32;
using QRCoder;

namespace CastMic;

public sealed class MainForm : Form
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const int HotkeyId = 1, WM_HOTKEY = 0x0312;
    const uint MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_NOREPEAT = 0x4000, VK_M = 0x4D;

    readonly Label _status = new() { Dock = DockStyle.Top, Height = 28, Padding = new Padding(8, 6, 8, 0) };
    readonly PictureBox _qr = new() { Dock = DockStyle.Left, Width = 180, SizeMode = PictureBoxSizeMode.Zoom };
    readonly Label _info = new() { Dock = DockStyle.Fill, Padding = new Padding(8, 4, 8, 0) };
    readonly Panel _top = new() { Dock = DockStyle.Top, Height = 180 };
    readonly Panel _pairRow = new() { Dock = DockStyle.Top, Height = 40, Padding = new Padding(8, 4, 8, 4) };
    readonly Label _code = new() { Dock = DockStyle.Fill, Font = new Font(FontFamily.GenericMonospace, 14, FontStyle.Bold), TextAlign = ContentAlignment.MiddleLeft };
    readonly Button _regen = new() { Dock = DockStyle.Right, Width = 110, Text = "コードを再生成" };
    readonly CheckBox _mute = new() { Dock = DockStyle.Top, Height = 28, Padding = new Padding(8, 0, 8, 0), Text = "マイクをミュート (Ctrl+Shift+M)" };
    readonly CheckBox _autostart = new() { Dock = DockStyle.Top, Height = 28, Padding = new Padding(8, 0, 8, 0), Text = "Windows 起動時にバックグラウンドで開始" };
    readonly Panel _relayRow = new() { Dock = DockStyle.Top, Height = 34, Padding = new Padding(8, 4, 8, 4) };
    readonly Label _relayLabel = new() { Dock = DockStyle.Left, Width = 120, Text = "中継 Mac:", TextAlign = ContentAlignment.MiddleLeft };
    readonly TextBox _relayHost = new() { Dock = DockStyle.Fill, PlaceholderText = "例: 172.16.11.105 (空欄 = 使わない)" };
    readonly Button _relayApply = new() { Dock = DockStyle.Right, Width = 70, Text = "適用" };
    RelayConnector? _relay;
    readonly CheckBox _allowReverse = new() { Dock = DockStyle.Top, Height = 28, Padding = new Padding(8, 0, 8, 0), Text = "Mac から Windows のマイク / スピーカーを使うことを許可 (逆方向)" };
    readonly ListBox _clients = new() { Dock = DockStyle.Top, Height = 64 };
    readonly TextBox _log = new() { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
    readonly NotifyIcon _tray = new() { Icon = TrayIcons.Idle, Text = "CastMic", Visible = true };
    readonly bool _startHidden = Environment.GetCommandLineArgs().Contains("--background");
    IAudioBridge? _bridge;
    CastServer? _server;
    MdnsAdvertiser? _mdns;
    VirtualCamera? _camera;
    X509Certificate2? _cert;
    string _codeValue = "";
    bool _quitting, _hasClients;

    public MainForm()
    {
        Text = "CastMic";
        using (var s = typeof(MainForm).Assembly.GetManifestResourceStream("CastMic.ico")) if (s != null) Icon = new Icon(s);
        Width = 520; Height = 600;
        _top.Controls.Add(_info);
        _top.Controls.Add(_qr);
        _pairRow.Controls.Add(_code);
        _pairRow.Controls.Add(_regen);
        Controls.Add(_log);
        Controls.Add(_clients);
        _relayRow.Controls.Add(_relayHost);
        _relayRow.Controls.Add(_relayLabel);
        _relayRow.Controls.Add(_relayApply);
        Controls.Add(_relayRow);
        Controls.Add(_allowReverse);
        Controls.Add(_autostart);
        Controls.Add(_mute);
        Controls.Add(_pairRow);
        Controls.Add(_top);
        Controls.Add(_status);

        var menu = new ContextMenuStrip();
        menu.Items.Add("開く", null, (_, _) => ShowWindow());
        menu.Items.Add("ミュート切り替え", null, (_, _) => ToggleMute());
        menu.Items.Add("終了", null, (_, _) => { _quitting = true; Close(); });
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => ShowWindow();

        _autostart.Checked = Registry.CurrentUser.OpenSubKey(RunKey)?.GetValue("CastMic") != null;
        _autostart.CheckedChanged += (_, _) => SetAutostart(_autostart.Checked);
        _mute.CheckedChanged += (_, _) => { if (_server != null) _server.Muted = _mute.Checked; };
        _relayHost.Text = Settings.RelayHost;
        _relayApply.Click += (_, _) => { Settings.RelayHost = _relayHost.Text.Trim(); StartRelay(); ShowPairing(); };
        _allowReverse.Checked = Settings.AllowReverse;
        _allowReverse.CheckedChanged += (_, _) =>
        {
            Settings.AllowReverse = _allowReverse.Checked;
            if (_server == null) return;
            _server.AllowReverse = _allowReverse.Checked;
            // 許可を外したら、逆方向で接続中の端末も切る
            if (!_allowReverse.Checked) _server.DisconnectAll();
        };
        _regen.Click += (_, _) =>
        {
            _codeValue = Pairing.Regenerate();
            ShowPairing();
            if (_server != null) { _server.PairingCode = _codeValue; _server.DisconnectAll(); }
            AppendLog("ペアリングコードを再生成しました。接続中の端末は切断されました。");
        };

        Load += (_, _) => StartAll();
        Shown += (_, _) => { if (_startHidden) Hide(); };
        FormClosing += (_, e) =>
        {
            if (!_quitting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        };
        FormClosed += (_, _) =>
        {
            UnregisterHotKey(Handle, HotkeyId);
            _tray.Visible = false;
            _relay?.Dispose(); _mdns?.Dispose(); _server?.Dispose(); _camera?.Dispose(); _bridge?.Dispose();
        };
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (!RegisterHotKey(Handle, HotkeyId, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, VK_M))
            AppendLog("Ctrl+Shift+M は他のアプリが使用中のため登録できませんでした。");
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam == HotkeyId) ToggleMute();
        base.WndProc(ref m);
    }

    void ToggleMute() { if (_server != null) _server.Muted = !_server.Muted; }

    void ShowWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }

    static void SetAutostart(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) key.SetValue("CastMic", $"\"{Environment.ProcessPath}\" --background");
        else key.DeleteValue("CastMic", false);
    }

    void StartAll()
    {
        _codeValue = Pairing.Load();
        try { _cert = ServerIdentity.LoadOrCreate(); }
        catch (CryptographicException ex) { Fail("証明書の作成に失敗しました", ex.Message); return; }
        ShowPairing();

        try { _bridge = (IAudioBridge?)DriverBridge.TryOpen() ?? CableBridge.TryCreate(); }
        catch (Exception ex) when (ex is InvalidOperationException or COMException) { Fail("オーディオの初期化に失敗しました", ex.Message); return; }
        if (_bridge == null) { Fail("オーディオデバイスが見つかりません", "CastMic ドライバも VB-CABLE も見つかりません。どちらかをインストールしてください。"); return; }

        AppendLog($"オーディオ: {_bridge.Name}");
        if (_bridge is DriverBridge db) db.Error += AppendLog;
        _bridge.Start();

        _server = new CastServer(_bridge, _codeValue, _cert) { AllowReverse = Settings.AllowReverse };
        _server.ReverseStarted += name => Ui(() =>
            _tray.ShowBalloonTip(5000, "CastMic", $"{name} が Windows のマイクを使っています", ToolTipIcon.Warning));
        _server.Log += AppendLog;
        _server.ClientHello += name => Notify($"{name} が接続しました");
        _server.ClientsChanged += list => Ui(() =>
        {
            _hasClients = list.Count > 0;
            _clients.Items.Clear();
            foreach (var l in list) _clients.Items.Add(l);
            _status.Text = _hasClients ? $"接続中: {list.Count} 台" : $"待機中 (TCP {CastServer.Port})";
            UpdateTray();
        });
        _server.MuteChanged += muted => Ui(() =>
        {
            _mute.Checked = muted;
            UpdateTray();
            Notify(muted ? "マイクをミュートしました" : "マイクのミュートを解除しました");
        });
        _camera = new VirtualCamera();
        if (_camera.Start())
        {
            AppendLog("仮想カメラ「CastMic Camera」を登録しました。");
            _server.CameraFrame += _camera.PushJpeg;
        }
        else AppendLog(_camera.Error ?? "仮想カメラを開始できませんでした。");

        _server.Start();
        _status.Text = $"待機中 (TCP {CastServer.Port})";

        StartRelay();
        _mdns = new MdnsAdvertiser();
        AppendLog(_mdns.Start(CastServer.Port) ? $"自動検出を有効化: {Environment.MachineName}" : "自動検出 (mDNS) を開始できませんでした。IP で接続してください。");
    }

    /// 中継 Mac に待ち受け用の接続を張る (iPhone と PC が直接つながらないネットワーク用)
    void StartRelay()
    {
        _relay?.Dispose();
        _relay = null;
        var host = Settings.RelayHost;
        if (_server == null || _cert == null || string.IsNullOrWhiteSpace(host)) return;
        if (!RelayConnector.TryParse(host, out var h, out var port))
        {
            AppendLog($"中継 Mac のアドレスが不正です: {host}");
            return;
        }
        _relay = new RelayConnector(h, port, RelayConnector.RoomFor(ServerIdentity.Fingerprint(_cert)), _server);
        _relay.Log += AppendLog;
        _relay.Start();
        AppendLog($"中継 Mac {h}:{port} を使います。");
    }

    void Fail(string status, string detail)
    {
        _status.Text = status;
        AppendLog(detail);
        ShowWindow();
    }

    void UpdateTray()
    {
        var muted = _server?.Muted == true;
        _tray.Icon = muted ? TrayIcons.Muted : _hasClients ? TrayIcons.Live : TrayIcons.Idle;
        _tray.Text = muted ? "CastMic - ミュート中" : _hasClients ? "CastMic - 接続中" : "CastMic - 待機中";
    }

    /// QR = castmic://pair?n=PC名&a=IP1,IP2&p=ポート&c=コード&f=証明書指紋
    /// iPhone のカメラで読むとアプリが開き、証明書を最初から信頼した状態で接続する
    void ShowPairing()
    {
        _code.Text = $"ペアリングコード: {_codeValue[..3]} {_codeValue[3..]}";
        if (_cert == null) return;
        var fp = ServerIdentity.Fingerprint(_cert);
        var addrs = LocalAddresses().Select(a => a.addr).ToList();
        var url = $"castmic://pair?n={Uri.EscapeDataString(Environment.MachineName)}&a={string.Join(",", addrs)}&p={CastServer.Port}&c={_codeValue}&f={fp}";
        if (RelayConnector.TryParse(Settings.RelayHost, out var rh, out var rp)) url += $"&r={Uri.EscapeDataString($"{rh}:{rp}")}";
        using var gen = new QRCodeGenerator();
        using var data = gen.CreateQrCode(url, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(6);
        _qr.Image?.Dispose();
        _qr.Image = Image.FromStream(new MemoryStream(png));

        _info.Text = "iPhone のカメラでこの QR を読むと接続できます。\r\n\r\n"
            + "Mac / 手動の場合は IP とコードを入力:\r\n"
            + string.Join("\r\n", LocalAddresses().Select(a => $"  {a.addr}  ({a.name})"))
            + $"\r\n\r\n確認コード: {ServerIdentity.ShortFingerprint(fp)}";
    }

    void Notify(string text) => Ui(() => _tray.ShowBalloonTip(2000, "CastMic", text, ToolTipIcon.Info));

    static IEnumerable<(string addr, string name)> LocalAddresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses
                .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                .Select(a => (a.Address.ToString(), n.Name)));

    void AppendLog(string s) => Ui(() => _log.AppendText($"[{DateTime.Now:HH:mm:ss}] {s}\r\n"));
    void Ui(Action a) { if (IsHandleCreated) BeginInvoke(a); }

    [DllImport("user32", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32", SetLastError = true)] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
