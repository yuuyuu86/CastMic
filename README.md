# CastMic

iPhone / Mac を Windows の **マイク** と **スピーカー** として使うためのアプリ。
接続は Wi-Fi または USB 有線 (USB テザリング経由)。

```
[iPhone / Mac]  --- TCP 48100 (Wi-Fi or USB tethering) ---  [Windows]
  mic  ─────────── MicAudio ──────────────────────────────▶  CastMic Microphone (仮想入力)
  speaker ◀──────── SpeakerAudio ──────────────────────────  CastMic Speaker   (仮想出力)
```

| ディレクトリ | 内容 |
|---|---|
| `apple/` | iOS / macOS 共通 SwiftUI アプリ (送信側) |
| `windows/` | Windows 受信アプリ (C# / .NET 8, WinForms) |
| `mac-driver/` | macOS 仮想オーディオデバイス (AudioServerPlugIn, 逆方向モード用) |
| `windows/CastMicCam/` | Windows 11 仮想カメラ (Media Foundation メディアソース DLL) |
| `driver/` | Windows 仮想オーディオドライバ (WDK / PortCls WaveRT) |
| `docs/` | プロトコル仕様 |

## 現在の状態

| 部分 | ビルド (CI) | 動作確認 |
|---|---|---|
| iPhone / Mac アプリ | ✅ | ✅ シミュレータ + Mac 上のサーバーで QR ペアリング・TLS・Opus・ミュート連動を確認 |
| Opus 相互運用 (CoreAudio ⇔ Concentus) | ✅ | ✅ 両方向でデコード一致を確認 |
| Mac 仮想オーディオ (mac-driver) | ✅ | ✅ 読み込み・ループバックをテストで確認 (coreaudiod へのインストールは未確認) |
| Windows アプリ / インストーラー | ✅ | ❌ 実機未確認 |
| Windows 仮想オーディオドライバ | ✅ | ❌ 実機未確認 (VM 推奨) |
| Windows 仮想カメラ (Windows 11) | ✅ | ❌ 実機未確認 |

ドライバが動かない場合も、Windows アプリは VB-CABLE があればそれを使って動く。

## 機能

- **2 方向**: iPhone / Mac を Windows のマイク・スピーカーに / Windows のマイク・スピーカーを Mac で使う (逆方向, Mac 用ドライバが必要)
- **QR コードでペアリング**: Windows に出る QR を iPhone で読むだけで接続 (証明書も QR で受け取るのでなりすまし不可)
- **ミュート**: iPhone のロック画面 / Dynamic Island、Windows の Ctrl+Shift+M、トレイから。全端末で連動
- **音声圧縮 (Opus)**: 通信量 1/10。遅延 (40〜300ms) をスライダーで調整
- **複数台同時接続** (最大 4 台): 例) iPhone をマイク、Mac をスピーカーに
- **Web カメラ**: iPhone / Mac のカメラを Windows 11 の「CastMic Camera」として使う (720p / 30fps)
- **Windows インストーラー**: アプリ・ドライバ・ファイアウォール設定を一括 (CI の Artifacts `CastMic-Setup`)

- 同じネットワーク上の PC を自動検出 (mDNS)。IP 直接入力も可
- 切断時の自動再接続
- 往復遅延の表示
- マイク音量 (×0〜4)、ノイズ抑制・エコーキャンセルの切り替え
- Windows: タスクトレイ常駐、接続通知、Windows 起動時の自動開始

## 使い方

1. Windows で `windows/` をビルドして起動 (ファイアウォールで TCP 48100 を許可)
2. iPhone/Mac でアプリを起動し、Windows に表示される **ペアリングコード** を入力して、見つかった PC (または IP) を選んで接続
   - 有線: iPhone の「インターネット共有」をオンにして USB 接続 → Windows の IP (`ipconfig` で 172.20.10.x) を入力

## セキュリティ

- 接続には Windows に表示される 6 桁のペアリングコードが必要 (コードを知らない端末は PC の音を聞けない)
- 通信は TLS で暗号化。PC の証明書は初回接続時に記憶し、以後変わったら接続を拒否する (なりすまし対策)
- 初回接続時は、iPhone/Mac に出る「確認コード」が Windows の表示と一致するか確認すると確実

## ビルド

GitHub Actions (`.github/workflows/build.yml`) が push ごとに 3 つともビルドし、Windows アプリとドライバを Artifacts に置く。

```bash
cd apple && xcodegen && open CastMic.xcodeproj
```

```bash
cd windows/CastMic.Windows && dotnet build
```
