// CastMicHAL.driver を CFPlugIn として読み込み、HAL と同じ呼び方で検証する (インストール不要)
#include <CoreAudio/AudioServerPlugIn.h>
#include <stdio.h>
#include <math.h>

#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s\n", msg); return 1; } else printf("ok   %s\n", msg); } while (0)

int main(int argc, char** argv)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)argv[1], strlen(argv[1]), true);
    CFPlugInRef plugin = CFPlugInCreate(NULL, url);
    CHECK(plugin, "plugin bundle loads");
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    CHECK(factories && CFArrayGetCount(factories) == 1, "factory registered for AudioServerPlugIn type");
    IUnknownVTbl** unk = CFPlugInInstanceCreate(NULL, CFArrayGetValueAtIndex(factories, 0), kAudioServerPlugInTypeUUID);
    CHECK(unk, "factory creates instance");
    AudioServerPlugInDriverRef drv = NULL;
    (*unk)->QueryInterface(unk, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), (LPVOID*)&drv);
    CHECK(drv, "QueryInterface returns driver interface");
    CHECK((*drv)->Initialize(drv, NULL) == 0, "Initialize");

    AudioObjectPropertyAddress a = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0 };
    UInt32 size = 0;
    (*drv)->GetPropertyDataSize(drv, kAudioObjectPlugInObject, 0, &a, 0, NULL, &size);
    AudioObjectID devs[4]; UInt32 got = 0;
    (*drv)->GetPropertyData(drv, kAudioObjectPlugInObject, 0, &a, 0, NULL, sizeof(devs), &got, devs);
    CHECK(got / sizeof(AudioObjectID) == 2, "two devices");

    for (int i = 0; i < 2; i++)
    {
        CFStringRef name = NULL;
        a.mSelector = kAudioObjectPropertyName;
        (*drv)->GetPropertyData(drv, devs[i], 0, &a, 0, NULL, sizeof(name), &got, &name);
        char buf[64]; CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8); CFRelease(name);
        a.mSelector = kAudioDevicePropertyStreams; a.mScope = kAudioObjectPropertyScopeInput;
        AudioObjectID st[2]; (*drv)->GetPropertyData(drv, devs[i], 0, &a, 0, NULL, sizeof(st), &got, st);
        UInt32 nin = got / 4;
        a.mScope = kAudioObjectPropertyScopeOutput;
        (*drv)->GetPropertyData(drv, devs[i], 0, &a, 0, NULL, sizeof(st), &got, st);
        UInt32 nout = got / 4;
        a.mScope = kAudioObjectPropertyScopeGlobal;
        printf("     device %u \"%s\" in=%u out=%u\n", devs[i], buf, nin, nout);
        CHECK(nin == 1 && nout == 1, "device has one input and one output stream");
    }

    // UID → デバイス変換
    CFStringRef uid = CFSTR("CastMic.Speaker"); AudioObjectID found = 0;
    a.mSelector = kAudioPlugInPropertyTranslateUIDToDevice;
    (*drv)->GetPropertyData(drv, kAudioObjectPlugInObject, 0, &a, sizeof(uid), &uid, sizeof(found), &got, &found);
    CHECK(found == devs[1], "TranslateUIDToDevice");

    // 未知のプロパティ / オブジェクト
    a.mSelector = 'zzzz';
    CHECK(!(*drv)->HasProperty(drv, devs[0], 0, &a), "unknown property reported as absent");
    a.mSelector = kAudioObjectPropertyName;
    CHECK(!(*drv)->HasProperty(drv, 999, 0, &a), "unknown object reported as absent");

    // ループバック: WriteMix した 1kHz サイン波が同じ時刻の ReadInput で返る
    AudioObjectID dev = devs[0];
    CHECK((*drv)->StartIO(drv, dev, 1) == 0, "StartIO");
    enum { N = 512 };
    float out[N * 2], in[N * 2];
    for (int k = 0; k < N; k++) out[k*2] = out[k*2+1] = sinf(k * 2 * M_PI * 1000 / 48000);
    AudioServerPlugInIOCycleInfo info = {0};
    info.mOutputTime.mSampleTime = 16000;   // リング境界 (16384) をまたぐ
    info.mInputTime.mSampleTime = 16000;
    (*drv)->DoIOOperation(drv, dev, 0, 1, kAudioServerPlugInIOOperationWriteMix, N, &info, out, NULL);
    (*drv)->DoIOOperation(drv, dev, 0, 1, kAudioServerPlugInIOOperationReadInput, N, &info, in, NULL);
    float maxdiff = 0; for (int k = 0; k < N * 2; k++) maxdiff = fmaxf(maxdiff, fabsf(in[k] - out[k]));
    CHECK(maxdiff == 0, "loopback returns written samples across ring wrap");
    (*drv)->DoIOOperation(drv, dev, 0, 1, kAudioServerPlugInIOOperationReadInput, N, &info, in, NULL);
    float peak = 0; for (int k = 0; k < N * 2; k++) peak = fmaxf(peak, fabsf(in[k]));
    CHECK(peak == 0, "second read is silent (no stale repeat)");

    // 他のデバイスには漏れない
    (*drv)->StartIO(drv, devs[1], 1);
    (*drv)->DoIOOperation(drv, devs[0], 0, 1, kAudioServerPlugInIOOperationWriteMix, N, &info, out, NULL);
    (*drv)->DoIOOperation(drv, devs[1], 0, 1, kAudioServerPlugInIOOperationReadInput, N, &info, in, NULL);
    peak = 0; for (int k = 0; k < N * 2; k++) peak = fmaxf(peak, fabsf(in[k]));
    CHECK(peak == 0, "devices are isolated");

    Float64 st; UInt64 ht, seed;
    CHECK((*drv)->GetZeroTimeStamp(drv, dev, 1, &st, &ht, &seed) == 0, "GetZeroTimeStamp");
    a.mSelector = kAudioDevicePropertyDeviceIsRunning; UInt32 running = 0;
    (*drv)->GetPropertyData(drv, dev, 0, &a, 0, NULL, 4, &got, &running);
    CHECK(running == 1, "IsRunning while IO started");
    (*drv)->StopIO(drv, dev, 1);
    (*drv)->GetPropertyData(drv, dev, 0, &a, 0, NULL, 4, &got, &running);
    CHECK(running == 0, "not running after StopIO");
    printf("ALL PASSED\n");
    return 0;
}
