# CastMic Protocol v1

送信側 (iPhone / Mac アプリ) が **クライアント**、Windows アプリが **サーバー** (TCP `48100`)。
Wi-Fi でも USB テザリング (iPhone の個人用ホットスポットを USB で有効化) でも同じ TCP で通信する。
USB テザリング時、iPhone は通常 `172.20.10.1`、Windows は `172.20.10.x` になる。

## 認証

接続後 5 秒以内に送信側が Hello (ペアリングコード付き, 最大 1KB) を送る。
コードが一致するまで Windows は音声を送受信しない。不一致なら 1 秒待って AuthFailed を返して切断する。
認証前の同時接続は 4 本まで。認証済みの新しい接続だけが既存の接続を置き換える。

## 暗号化

TCP 接続の上で TLS 1.2 / 1.3 を張り、その中で下記フレームをやり取りする。

- Windows は自己署名証明書 (ECDSA P-256, `CN=CastMic Server`) を生成し、CurrentUser\My ストアに保存して使い回す
- 送信側は証明書チェーンを検証せず、葉証明書 DER の SHA-256 指紋で判定する
  - 初回 (その接続先の指紋を未記憶): 受け入れ、ペアリングコードが通った時点で指紋を記憶する (TOFU)
  - 2 回目以降: 記憶した指紋と一致しなければ接続を拒否し、自動再接続もしない
- 確認コード = 指紋の先頭 16 桁。Windows と送信側の両方に表示され、初回接続時に目視で照合できる

## 自動検出

Windows アプリは mDNS で `_castmic._tcp` (サービス名 = PC 名, port 48100) を広告する。

## フレーム

全てリトルエンディアン。payload は最大 64KB。`TCP_NODELAY` 有効。

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
| 1 | Hello | 双方向 | UTF-8 JSON。送信側→Win: `{"name":"...","version":1,"code":"123456"}`、Win→送信側: `{"name":"...","version":1}` |
| 2 | MicAudio | 送信側 → Win | PCM s16le, 48000Hz, mono |
| 3 | SpeakerAudio | Win → 送信側 | PCM s16le, 48000Hz, stereo interleaved |
| 5 | AuthFailed | Win → 送信側 | 空。ペアリングコード不一致 (直後に切断) |
| 4 | Ping | 送信側 → Win → 送信側 | u64 タイムスタンプ(ms)。Windows はそのまま返す (送信側は返さない)。往復遅延の表示に使う |

音声フレームは 10ms 単位 (mono 960 byte / stereo 1920 byte) を推奨。
受信側はジッタバッファ (目標 40ms) を持ち、溢れたら古いデータを捨てる。
