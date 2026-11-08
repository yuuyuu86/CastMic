#include "common.h"

PVOID __cdecl operator new(size_t size, POOL_FLAGS flags, ULONG tag)
{
    return ExAllocatePool2(flags, size, tag); // ExAllocatePool2 はゼロ初期化する
}

PVOID __cdecl operator new(size_t size, POOL_FLAGS flags)
{
    return ExAllocatePool2(flags, size, CASTMIC_POOLTAG);
}

// operator delete(void*) は stdunk.lib が提供する (ExFreePool)
void __cdecl operator delete(PVOID p, size_t)    { if (p) ExFreePoolWithTag(p, CASTMIC_POOLTAG); }
void __cdecl operator delete[](PVOID p)          { if (p) ExFreePoolWithTag(p, CASTMIC_POOLTAG); }
