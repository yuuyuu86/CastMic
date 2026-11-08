# CastMic 仮想オーディオドライバ (開発中)

Windows に **CastMic Microphone** (入力) と **CastMic Speaker** (出力) を追加するカーネルモードドライバ。

## 状態

- [x] ユーザーモードとの IOCTL インターフェース定義 (`inc/CastMicIoctl.h`)
- [ ] ドライバ本体 (未着手)

完成までは Windows アプリが VB-CABLE フォールバックで動作する。

## 実装方針

Microsoft の [SYSVAD サンプル](https://github.com/microsoft/Windows-driver-samples/tree/main/audio/sysvad) (PortCls / WaveRT miniport) をベースにする。

1. SYSVAD の `TabletAudioSample` から不要な endpoint を削り、Speaker (render, 48k/16bit/2ch) と Mic (capture, 48k/16bit/1ch) の 2 つだけ残す
2. 各 WaveRT stream の DMA バッファ更新処理 (`CMiniportWaveRTStream::WriteBytes` / `ReadBytes` 相当) をリングバッファ読み書きに置き換える
3. 追加のコントロールデバイス `\Device\CastMicAudio` を作り、`IRP_MJ_DEVICE_CONTROL` で上記 IOCTL を処理する
4. INF 作成、テスト署名で動作確認 (`bcdedit /set testsigning on`)
5. 配布は EV 証明書 + Microsoft の attestation signing が必要

## 必要環境 (Windows PC)

- Visual Studio 2022 + WDK
- テスト用に別 PC / VM 推奨 (カーネルドライバのバグは BSOD になる)
