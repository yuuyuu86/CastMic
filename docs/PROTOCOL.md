# CastMic Protocol v1

送信側 (iPhone / Mac アプリ) が **クライアント**、Windows アプリが **サーバー** (TCP `48100`)。
Wi-Fi でも USB テザリング (iPhone の個人用ホットスポットを USB で有効化) でも同じ TCP で通信する。
USB テザリング時、iPhone は通常 `172.20.10.1`、Windows は `172.20.10.x` になる。

## 自動検出

Windows アプリは mDNS で `_castmic._tcp` (サービス名 = PC 名, port 48100) を広告する。

## フレーム

全てリトルエンディアン。`TCP_NODELAY` 有効。

| offset | size | 内容 |
|---|---|---|
| 0 | 2 | magic `0x43 0x4D` ("CM") |
| 2 | 1 | type |
| 3 | 1 | flags (予約, 0) |
| 4 | 4 | payload length (u32) |
| 8 | n | payload |

## type

| 値 | 名前 | 方向 | payload |
|---|---|---|---|
| 1 | Hello | 双方向 | UTF-8 JSON `{"name":"...","version":1}` |
| 2 | MicAudio | 送信側 → Win | PCM s16le, 48000Hz, mono |
| 3 | SpeakerAudio | Win → 送信側 | PCM s16le, 48000Hz, stereo interleaved |
| 4 | Ping | 送信側 → Win → 送信側 | u64 タイムスタンプ(ms)。Windows はそのまま返す (送信側は返さない)。往復遅延の表示に使う |

音声フレームは 10ms 単位 (mono 960 byte / stereo 1920 byte) を推奨。
受信側はジッタバッファ (目標 40ms) を持ち、溢れたら古いデータを捨てる。
