#pragma once

#define _NEW_DELETE_OPERATORS_
#include <portcls.h>
#include <stdunk.h>
#include <ksmedia.h>
#include <wdmsec.h>
#include "..\inc\CastMicIoctl.h"

#define CASTMIC_POOLTAG 'cMsC'

// --- new/delete (newdelete.cpp) ---
PVOID __cdecl operator new(size_t size, POOL_FLAGS flags, ULONG tag);
PVOID __cdecl operator new(size_t size, POOL_FLAGS flags);
void __cdecl operator delete(PVOID p, size_t);
void __cdecl operator delete[](PVOID p);

// --- リングバッファ (ringbuffer.cpp) ---
// 満杯時は古いデータを上書きする (遅延を溜めない)。DISPATCH_LEVEL 以下から呼べる。
struct RingBuffer
{
    KSPIN_LOCK Lock;
    PUCHAR     Data;
    ULONG      Size;
    ULONG      ReadPos;
    ULONG      Count;

    void  Init(PUCHAR data, ULONG size);
    void  Write(const UCHAR* src, ULONG len);
    ULONG Read(PUCHAR dst, ULONG len);
    void  Clear();
};

extern RingBuffer g_MicRing;   // ユーザーモード -> キャプチャストリーム (mono)
extern RingBuffer g_SpkRing;   // レンダーストリーム -> ユーザーモード (stereo)

// --- コントロールデバイス (control.cpp) ---
NTSTATUS CreateControlDevice(PDRIVER_OBJECT DriverObject);
void     DeleteControlDevice();
BOOLEAN  IsControlDevice(PDEVICE_OBJECT DeviceObject);
NTSTATUS DispatchControlDevice(PDEVICE_OBJECT DeviceObject, PIRP Irp);

// --- ミニポート生成 ---
NTSTATUS CreateMiniportWaveRT(PUNKNOWN* Unknown, BOOLEAN Capture);
NTSTATUS CreateMiniportTopology(PUNKNOWN* Unknown, BOOLEAN Capture);

// フォーマット (固定)
#define SPK_BLOCK_ALIGN (CASTMIC_SPK_CH * CASTMIC_BITS / 8)
#define MIC_BLOCK_ALIGN (CASTMIC_MIC_CH * CASTMIC_BITS / 8)

// フィルタのピン番号
#define WAVE_PIN_STREAM  0  // render: sink (in) / capture: 下記参照
#define WAVE_PIN_BRIDGE  1
// capture の wave フィルタは pin0 = bridge(in), pin1 = stream(out)
#define TOPO_PIN_WAVE    0  // render: bridge(in) / capture: 下記参照
#define TOPO_PIN_LINE    1
// capture の topology フィルタは pin0 = mic(in), pin1 = bridge(out)
