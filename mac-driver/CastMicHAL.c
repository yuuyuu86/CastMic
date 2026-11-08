// CastMic macOS 仮想オーディオデバイス (AudioServerPlugIn)
//
// 2 つのループバックデバイスを追加する:
//   "CastMic Microphone" … CastMic アプリが出力側に Windows のマイク音声を書き込み、他のアプリが入力として録音する
//   "CastMic Speaker"    … 他のアプリが出力した音を、CastMic アプリが入力側から読み取って Windows に送る
// 各デバイスは 48kHz / float32 / 2ch 固定。出力に書かれた音がそのまま同じデバイスの入力に出る。

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#define kSampleRate        48000.0
#define kChannels          2
#define kBytesPerFrame     (sizeof(Float32) * kChannels)
#define kRingFrames        16384   // ZeroTimeStampPeriod も兼ねる
#define kPlugInObject      kAudioObjectPlugInObject   // = 1

enum { kDeviceCount = 2 };

typedef struct {
    AudioObjectID device, inStream, outStream;
    CFStringRef   name, uid;
    UInt32        inTerminal, outTerminal;
    Float32       ring[kRingFrames * kChannels];
    UInt32        ioClients;
    UInt64        anchorHostTime;
    pthread_mutex_t lock;
} Device;

static Device gDevices[kDeviceCount] = {
    { 2, 3, 4, CFSTR("CastMic Microphone"), CFSTR("CastMic.Microphone"),
      kAudioStreamTerminalTypeMicrophone, kAudioStreamTerminalTypeLine, {0}, 0, 0, PTHREAD_MUTEX_INITIALIZER },
    { 5, 6, 7, CFSTR("CastMic Speaker"), CFSTR("CastMic.Speaker"),
      kAudioStreamTerminalTypeLine, kAudioStreamTerminalTypeSpeaker, {0}, 0, 0, PTHREAD_MUTEX_INITIALIZER },
};

static AudioServerPlugInHostRef gHost = NULL;
static atomic_uint gRefCount = 0;
static Float64 gHostTicksPerFrame = 0;

// ------------------------------------------------------------------ 前方宣言

static HRESULT  QueryInterface(void*, REFIID, LPVOID*);
static ULONG    AddRef(void*);
static ULONG    Release(void*);
static OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice,
    AddDeviceClient, RemoveDeviceClient, PerformDeviceConfigurationChange, AbortDeviceConfigurationChange,
    HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// ------------------------------------------------------------------ ファクトリ / COM

void* CastMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void* CastMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

static HRESULT QueryInterface(void* driver, REFIID uuid, LPVOID* out)
{
    if (driver != gDriverRef || out == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID))
    {
        AddRef(driver);
        *out = gDriverRef;
        r = S_OK;
    }
    CFRelease(req);
    return r;
}

static ULONG AddRef(void* driver)  { (void)driver; return atomic_fetch_add(&gRefCount, 1) + 1; }
static ULONG Release(void* driver) { (void)driver; UInt32 v = atomic_load(&gRefCount); if (v > 0) v = atomic_fetch_sub(&gRefCount, 1) - 1; return v; }

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host)
{
    (void)driver;
    gHost = host;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    return 0;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* out)
{ (void)d; (void)desc; (void)ci; (void)out; return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id)
{ (void)d; (void)id; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci)
{ (void)d; (void)id; (void)ci; return 0; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci)
{ (void)d; (void)id; (void)ci; return 0; }
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i)
{ (void)d; (void)id; (void)a; (void)i; return 0; }
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i)
{ (void)d; (void)id; (void)a; (void)i; return 0; }

// ------------------------------------------------------------------ オブジェクト検索

typedef enum { kKindNone, kKindPlugIn, kKindDevice, kKindInStream, kKindOutStream } Kind;

static Kind Lookup(AudioObjectID obj, Device** outDev)
{
    if (obj == kPlugInObject) return kKindPlugIn;
    for (int i = 0; i < kDeviceCount; i++)
    {
        Device* d = &gDevices[i];
        if (outDev) *outDev = d;
        if (obj == d->device) return kKindDevice;
        if (obj == d->inStream) return kKindInStream;
        if (obj == d->outStream) return kKindOutStream;
    }
    return kKindNone;
}

static AudioStreamBasicDescription Format(void)
{
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

// ------------------------------------------------------------------ プロパティ
// 1 つの関数でサイズ計算 (out == NULL) と値の取得を兼ねる

#define PUT(type, value) do {                                         \
        *outSize = sizeof(type);                                      \
        if (out) { if (cap < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type*)out = (value); } \
        return 0;                                                     \
    } while (0)

#define PUT_CFSTR(value) do {                                         \
        *outSize = sizeof(CFStringRef);                               \
        if (out) { if (cap < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
                   CFStringRef s_ = (value); CFRetain(s_); *(CFStringRef*)out = s_; } \
        return 0;                                                     \
    } while (0)

static OSStatus PutIDs(const AudioObjectID* ids, UInt32 n, UInt32 cap, UInt32* outSize, void* out)
{
    if (out)
    {
        UInt32 fit = cap / sizeof(AudioObjectID);
        if (fit < n) n = fit;
        memcpy(out, ids, n * sizeof(AudioObjectID));
    }
    *outSize = n * sizeof(AudioObjectID);
    return 0;
}

static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress* a,
                         UInt32 qSize, const void* q, UInt32 cap, UInt32* outSize, void* out)
{
    Device* d = NULL;
    Kind kind = Lookup(obj, &d);
    AudioObjectPropertyScope scope = a->mScope;

    switch (kind)
    {
    case kKindPlugIn:
        switch (a->mSelector)
        {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT_CFSTR(CFSTR("CastMic"));
        case kAudioPlugInPropertyResourceBundle: PUT_CFSTR(CFSTR(""));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        {
            AudioObjectID ids[kDeviceCount] = { gDevices[0].device, gDevices[1].device };
            return PutIDs(ids, kDeviceCount, cap, outSize, out);
        }
        case kAudioPlugInPropertyTranslateUIDToDevice:
        {
            AudioObjectID found = kAudioObjectUnknown;
            if (qSize == sizeof(CFStringRef) && q)
                for (int i = 0; i < kDeviceCount; i++)
                    if (CFEqual(*(const CFStringRef*)q, gDevices[i].uid)) found = gDevices[i].device;
            PUT(AudioObjectID, found);
        }
        }
        break;

    case kKindDevice:
        switch (a->mSelector)
        {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kPlugInObject);
        case kAudioObjectPropertyName:      PUT_CFSTR(d->name);
        case kAudioObjectPropertyManufacturer: PUT_CFSTR(CFSTR("CastMic"));
        case kAudioDevicePropertyDeviceUID: PUT_CFSTR(d->uid);
        case kAudioDevicePropertyModelUID:  PUT_CFSTR(CFSTR("CastMic.Loopback"));
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: return PutIDs(&d->device, 1, cap, outSize, out);
        case kAudioDevicePropertyClockDomain: PUT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning:
        {
            pthread_mutex_lock(&d->lock);
            UInt32 running = d->ioClients > 0;
            pthread_mutex_unlock(&d->lock);
            PUT(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0);
        case kAudioDevicePropertyLatency:      PUT(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates:
        {
            AudioValueRange r = { kSampleRate, kSampleRate };
            PUT(AudioValueRange, r);
        }
        case kAudioDevicePropertyIsHidden: PUT(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kRingFrames);
        case kAudioObjectPropertyControlList: *outSize = 0; return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
        {
            *outSize = 2 * sizeof(UInt32);
            if (out) { if (cap < *outSize) return kAudioHardwareBadPropertySizeError; ((UInt32*)out)[0] = 1; ((UInt32*)out)[1] = 2; }
            return 0;
        }
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
        {
            AudioObjectID ids[2];
            UInt32 n = 0;
            if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput)  ids[n++] = d->inStream;
            if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) ids[n++] = d->outStream;
            return PutIDs(ids, n, cap, outSize, out);
        }
        }
        break;

    case kKindInStream:
    case kKindOutStream:
    {
        Boolean input = kind == kKindInStream;
        switch (a->mSelector)
        {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:     PUT(AudioObjectID, d->device);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
        case kAudioStreamPropertyIsActive:  PUT(UInt32, 1);
        case kAudioStreamPropertyDirection: PUT(UInt32, input ? 1 : 0);
        case kAudioStreamPropertyTerminalType: PUT(UInt32, input ? d->inTerminal : d->outTerminal);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
        case kAudioStreamPropertyLatency:   PUT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: PUT(AudioStreamBasicDescription, Format());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        {
            AudioStreamRangedDescription r;
            r.mFormat = Format();
            r.mSampleRateRange.mMinimum = r.mSampleRateRange.mMaximum = kSampleRate;
            PUT(AudioStreamRangedDescription, r);
        }
        }
        break;
    }

    case kKindNone:
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareUnknownPropertyError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a)
{
    (void)drv; (void)pid;
    UInt32 size = 0;
    // TranslateUIDToDevice は修飾子が要るのでサイズ計算だけ別扱い
    return Property(obj, a, 0, NULL, 0, &size, NULL) == 0;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out)
{
    (void)drv; (void)pid;
    UInt32 size = 0;
    OSStatus r = Property(obj, a, 0, NULL, 0, &size, NULL);
    if (r) return r;
    switch (a->mSelector)
    {
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        *out = true; break;
    default:
        *out = false;
    }
    return 0;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                    UInt32 qSize, const void* q, UInt32* outSize)
{
    (void)drv; (void)pid;
    return Property(obj, a, qSize, q, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qSize, const void* q, UInt32 inSize, UInt32* outSize, void* out)
{
    (void)drv; (void)pid;
    if (out == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    return Property(obj, a, qSize, q, inSize, outSize, out);
}

// 48kHz / float32 / 2ch 以外は受け付けない (同じ値を設定するのは許可)
static OSStatus SetPropertyData(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qSize, const void* q, UInt32 inSize, const void* in)
{
    (void)drv; (void)pid; (void)qSize; (void)q;
    if (Lookup(obj, NULL) == kKindNone) return kAudioHardwareBadObjectError;
    switch (a->mSelector)
    {
    case kAudioDevicePropertyNominalSampleRate:
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64*)in == kSampleRate ? 0 : kAudioDeviceUnsupportedFormatError;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
    {
        if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = in;
        AudioStreamBasicDescription ours = Format();
        return (f->mSampleRate == ours.mSampleRate && f->mFormatID == ours.mFormatID &&
                f->mChannelsPerFrame == ours.mChannelsPerFrame && f->mBitsPerChannel == ours.mBitsPerChannel)
            ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

// ------------------------------------------------------------------ IO

static Device* DeviceFor(AudioObjectID obj)
{
    Device* d = NULL;
    return Lookup(obj, &d) == kKindDevice ? d : NULL;
}

static OSStatus StartIO(AudioServerPlugInDriverRef drv, AudioObjectID obj, UInt32 client)
{
    (void)drv; (void)client;
    Device* d = DeviceFor(obj);
    if (!d) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&d->lock);
    if (d->ioClients++ == 0)
    {
        d->anchorHostTime = mach_absolute_time();
        memset(d->ring, 0, sizeof(d->ring));
    }
    pthread_mutex_unlock(&d->lock);
    return 0;
}

static OSStatus StopIO(AudioServerPlugInDriverRef drv, AudioObjectID obj, UInt32 client)
{
    (void)drv; (void)client;
    Device* d = DeviceFor(obj);
    if (!d) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&d->lock);
    if (d->ioClients > 0) d->ioClients--;
    pthread_mutex_unlock(&d->lock);
    return 0;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef drv, AudioObjectID obj, UInt32 client,
                                 Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)drv; (void)client;
    Device* d = DeviceFor(obj);
    if (!d) return kAudioHardwareBadObjectError;
    Float64 ticksPerPeriod = gHostTicksPerFrame * kRingFrames;
    UInt64 now = mach_absolute_time();
    UInt64 periods = (UInt64)((Float64)(now - d->anchorHostTime) / ticksPerPeriod);
    *outSampleTime = (Float64)(periods * kRingFrames);
    *outHostTime = d->anchorHostTime + (UInt64)(periods * ticksPerPeriod);
    *outSeed = 1;
    return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID obj, UInt32 client, UInt32 op,
                                  Boolean* outWillDo, Boolean* outInPlace)
{
    (void)drv; (void)obj; (void)client;
    Boolean will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = will;
    if (outInPlace) *outInPlace = true;
    return 0;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID obj, UInt32 client, UInt32 op, UInt32 frames,
                                 const AudioServerPlugInIOCycleInfo* info)
{ (void)drv; (void)obj; (void)client; (void)op; (void)frames; (void)info; return 0; }
static OSStatus EndIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID obj, UInt32 client, UInt32 op, UInt32 frames,
                               const AudioServerPlugInIOCycleInfo* info)
{ (void)drv; (void)obj; (void)client; (void)op; (void)frames; (void)info; return 0; }

// 出力 (WriteMix) をリングバッファのサンプル時刻の位置に書き、入力 (ReadInput) は同じ位置から読む
static OSStatus DoIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID obj, AudioObjectID stream, UInt32 client,
                              UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info, void* main, void* secondary)
{
    (void)drv; (void)stream; (void)client; (void)secondary;
    Device* d = DeviceFor(obj);
    if (!d || !main || frames > kRingFrames) return kAudioHardwareBadObjectError;

    Float32* buf = main;
    if (op == kAudioServerPlugInIOOperationWriteMix)
    {
        UInt64 start = (UInt64)info->mOutputTime.mSampleTime % kRingFrames;
        UInt32 first = (UInt32)(kRingFrames - start) < frames ? (UInt32)(kRingFrames - start) : frames;
        memcpy(&d->ring[start * kChannels], buf, first * kBytesPerFrame);
        memcpy(&d->ring[0], buf + first * kChannels, (frames - first) * kBytesPerFrame);
    }
    else if (op == kAudioServerPlugInIOOperationReadInput)
    {
        UInt64 start = (UInt64)info->mInputTime.mSampleTime % kRingFrames;
        UInt32 first = (UInt32)(kRingFrames - start) < frames ? (UInt32)(kRingFrames - start) : frames;
        memcpy(buf, &d->ring[start * kChannels], first * kBytesPerFrame);
        memcpy(buf + first * kChannels, &d->ring[0], (frames - first) * kBytesPerFrame);
        // 読んだ所は消す (書き手がいなくなったとき古い音が繰り返されないように)
        memset(&d->ring[start * kChannels], 0, first * kBytesPerFrame);
        memset(&d->ring[0], 0, (frames - first) * kBytesPerFrame);
    }
    return 0;
}
