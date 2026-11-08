# CastMic 仮想オーディオドライバ (開発中)

Windows に **CastMic Microphone** (入力) と **CastMic Speaker** (出力) を追加するカーネルモードドライバ。

## 構成

| ファイル | 内容 |
|---|---|
| `inc/CastMicIoctl.h` | ユーザーモードとの IOCTL 定義 (C# 側 `DriverBridge.cs` と一致させる) |
| `CastMicAudio/adapter.cpp` | DriverEntry、Speaker / Mic の wave+topology フィルタ登録、IRP 振り分け |
| `CastMicAudio/minwavert.cpp` | WaveRT ミニポート。10ms 高分解能タイマーで DMA バッファとリングバッファを相互コピー |
| `CastMicAudio/mintopo.cpp` | 最小トポロジー (物理ピンのカテゴリで スピーカー/マイク を決める) |
| `CastMicAudio/control.cpp` | `\\.\CastMicAudio` コントロールデバイスと IOCTL 処理 |
| `CastMicAudio/ringbuffer.cpp` | 200ms のリングバッファ (溢れたら古いデータを捨てる) |
| `CastMicAudio/CastMicAudio.inf` | INF (root 列挙デバイス) |

フォーマットは 48kHz / 16bit 固定 (Speaker 2ch, Mic 1ch)。

## 状態

GitHub Actions でビルド・テスト署名・パッケージ化まで通る。**実機 / VM での動作は未検証。**

## ビルド・インストール (Windows)

必要: Visual Studio 2022 + Windows Driver Kit (WDK)。**VM での検証を強く推奨** (バグは BSOD になる)。

1. ビルド済みのものを使う場合: GitHub の Actions → 最新の build → Artifacts から `CastMicAudio-driver-x64` をダウンロード。
   自分でビルドする場合: `CastMicAudio.vcxproj` を Visual Studio で開き、`Release|x64` でビルド (テスト署名が自動で付く)
   - テスト証明書 `CastMicAudio.cer` を「信頼されたルート証明機関」と「信頼された発行元」(ローカルコンピューター) にインポートする
2. テスト署名を許可して再起動 (管理者):
   ```
   bcdedit /set testsigning on
   ```
3. ビルド出力フォルダで、WDK の `devcon.exe` を使いインストール (管理者):
   ```
   devcon install CastMicAudio.inf Root\CastMicAudio
   ```
4. サウンド設定に「スピーカー (CastMic)」「マイク (CastMic)」が出れば成功。CastMic.exe を起動するとドライバを優先して使う
5. アンインストール: `devcon remove Root\CastMicAudio`

一般配布には EV コード署名証明書 + Microsoft Partner Center での attestation signing が必要。

## 既知の制限 / TODO

- 音量・ミュートノード無し (Windows の音量スライダーはソフトウェア処理になる)
- イベント駆動モード (`IMiniportWaveRTStreamNotification`) 未対応 → ポーリングモードで動作
- ジャック情報 (`KSPROPERTY_JACK_DESCRIPTION`) 未対応
