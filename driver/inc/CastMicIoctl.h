// CastMic 仮想オーディオドライバ <-> ユーザーモード (windows/CastMic.Windows/DriverBridge.cs) 共通定義
#pragma once

// ユーザーモードから開くシンボリックリンク: \\.\CastMicAudio
#define CASTMIC_DOS_DEVICE_NAME L"\\DosDevices\\CastMicAudio"
#define CASTMIC_DEVICE_NAME     L"\\Device\\CastMicAudio"

#define CASTMIC_SAMPLE_RATE 48000
#define CASTMIC_BITS        16
#define CASTMIC_MIC_CH      1   // キャプチャ endpoint "CastMic Microphone"
#define CASTMIC_SPK_CH      2   // レンダー endpoint   "CastMic Speaker"

// in: s16le mono PCM。ドライバはキャプチャ用リングバッファへ追記する
#define IOCTL_CASTMIC_WRITE_MIC \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

// out: s16le stereo PCM。レンダー用リングバッファから読み出す。
// 10ms 分 (1920 byte) 溜まるまで IRP を保留し、CancelIoEx でキャンセル可能にすること
#define IOCTL_CASTMIC_READ_SPEAKER \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
