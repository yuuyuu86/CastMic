#include "common.h"

void RingBuffer::Init(PUCHAR data, ULONG size)
{
    KeInitializeSpinLock(&Lock);
    Data = data;
    Size = size;
    ReadPos = 0;
    Count = 0;
}

void RingBuffer::Write(const UCHAR* src, ULONG len)
{
    KIRQL irql;
    KeAcquireSpinLock(&Lock, &irql);
    if (len >= Size)
    {
        // 末尾 Size バイトだけ残す
        src += len - Size;
        len = Size;
        ReadPos = 0;
        Count = 0;
    }
    ULONG overflow = (Count + len > Size) ? Count + len - Size : 0;
    if (overflow)
    {
        ReadPos = (ReadPos + overflow) % Size;
        Count -= overflow;
    }
    ULONG writePos = (ReadPos + Count) % Size;
    ULONG first = min(len, Size - writePos);
    RtlCopyMemory(Data + writePos, src, first);
    RtlCopyMemory(Data, src + first, len - first);
    Count += len;
    KeReleaseSpinLock(&Lock, irql);
}

ULONG RingBuffer::Read(PUCHAR dst, ULONG len)
{
    KIRQL irql;
    KeAcquireSpinLock(&Lock, &irql);
    ULONG n = min(len, Count);
    ULONG first = min(n, Size - ReadPos);
    RtlCopyMemory(dst, Data + ReadPos, first);
    RtlCopyMemory(dst + first, Data, n - first);
    ReadPos = (ReadPos + n) % Size;
    Count -= n;
    KeReleaseSpinLock(&Lock, irql);
    return n;
}

void RingBuffer::Clear()
{
    KIRQL irql;
    KeAcquireSpinLock(&Lock, &irql);
    ReadPos = 0;
    Count = 0;
    KeReleaseSpinLock(&Lock, irql);
}
