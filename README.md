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
- 自作ドライバ: コード実装済み・未ビルド (`driver/README.md`)。動くまでは Windows アプリの **VB-CABLE フォールバック** で動作確認できる。

## 使い方

1. Windows で `windows/` をビルドして起動 (ファイアウォールで TCP 48100 を許可)
2. iPhone/Mac でアプリを起動し、Windows の IP を入力して接続
   - 有線: iPhone の「インターネット共有」をオンにして USB 接続 → Windows の IP (`ipconfig` で 172.20.10.x) を入力

## ビルド

```bash
cd apple && xcodegen && open CastMic.xcodeproj
```

```bash
cd windows/CastMic.Windows && dotnet build
```
