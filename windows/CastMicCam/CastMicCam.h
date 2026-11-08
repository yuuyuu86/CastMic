// CastMic 仮想カメラ: アプリ (CastMic.exe) とメディアソース (Frame Server 内) の共有定義
#pragma once
#include <windows.h>

#define CASTMIC_CAM_WIDTH   1280
#define CASTMIC_CAM_HEIGHT  720
#define CASTMIC_CAM_FPS     30
#define CASTMIC_CAM_NV12_SIZE (CASTMIC_CAM_WIDTH * CASTMIC_CAM_HEIGHT * 3 / 2)

// メディアソース (LocalService) が作成し、ログオンユーザーの CastMic.exe が書き込む
#define CASTMIC_CAM_MAPPING_GLOBAL L"Global\\CastMicCamFrame"
#define CASTMIC_CAM_MAPPING_LOCAL  L"Local\\CastMicCamFrame"

// 共有メモリ先頭のヘッダ。seq は書き込み中は奇数 (seqlock)
struct CastMicCamHeader
{
    volatile LONG seq;
    UINT32 width;
    UINT32 height;
    UINT32 reserved;
    LONGLONG updatedQpc;  // 最終書き込み時刻 (QueryPerformanceCounter)
    BYTE pad[40];
};
static_assert(sizeof(CastMicCamHeader) == 64, "header must be 64 bytes");

#define CASTMIC_CAM_MAPPING_SIZE (sizeof(CastMicCamHeader) + CASTMIC_CAM_NV12_SIZE)

// {3F2A6D41-9C7B-4E5A-8D21-6B0C4E7F9A13}
static const CLSID CLSID_CastMicCam =
    { 0x3f2a6d41, 0x9c7b, 0x4e5a, { 0x8d, 0x21, 0x6b, 0x0c, 0x4e, 0x7f, 0x9a, 0x13 } };
