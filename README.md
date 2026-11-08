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
| `driver/` | Windows 仮想オーディオドライバ (WDK / PortCls WaveRT) |
| `docs/` | プロトコル仕様 |

## 現在の状態

- Apple アプリ / Windows アプリ: 基本機能実装済み (Windows 側は未実機検証)
- 自作ドライバ: CI でビルド・パッケージ化まで通る。実機未検証 (`driver/README.md`)。動くまでは Windows アプリの **VB-CABLE フォールバック** で動作確認できる。

## 機能

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
