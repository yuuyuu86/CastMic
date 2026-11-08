// CastMic 仮想カメラ (Windows 11 の MFCreateVirtualCamera 用メディアソース)
//
// - Frame Server が CLSID_CastMicCam を CoCreateInstance → Activator → MediaSource を作る
// - MediaSource は共有メモリ (NV12 1280x720) の最新フレームを 30fps で渡す
// - CastMic.exe は CastMicCam_Start() で仮想カメラを登録し、iPhone から届いた映像を共有メモリへ書く

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mfvirtualcamera.h>
#include <ks.h>
#include <ksproxy.h>
#include <ksmedia.h>
#include <sddl.h>
#include <wrl.h>
#include <wrl/module.h>
#include <mutex>
#include <new>
#include "CastMicCam.h"

using namespace Microsoft::WRL;

#define RETURN_IF_FAILED(x) do { HRESULT hr_ = (x); if (FAILED(hr_)) return hr_; } while (0)

// ------------------------------------------------------------------ 共有メモリ (読み手)

class FrameReader
{
public:
    void Open()
    {
        // Global は LocalService (Frame Server) なら作成できる。ユーザーの CastMic.exe が書けるよう IU に RW を与える
        SECURITY_ATTRIBUTES sa{ sizeof(sa), nullptr, FALSE };
        PSECURITY_DESCRIPTOR sd = nullptr;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:(A;;GA;;;SY)(A;;GA;;;LS)(A;;GA;;;BA)(A;;GRGW;;;IU)", SDDL_REVISION_1, &sd, nullptr))
            sa.lpSecurityDescriptor = sd;
        m_map = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0, CASTMIC_CAM_MAPPING_SIZE, CASTMIC_CAM_MAPPING_GLOBAL);
        if (!m_map)
            m_map = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0, CASTMIC_CAM_MAPPING_SIZE, CASTMIC_CAM_MAPPING_LOCAL);
        if (sd) LocalFree(sd);
        if (m_map) m_view = static_cast<BYTE*>(MapViewOfFile(m_map, FILE_MAP_READ, 0, 0, CASTMIC_CAM_MAPPING_SIZE));
        QueryPerformanceFrequency(&m_freq);
    }

    ~FrameReader()
    {
        if (m_view) UnmapViewOfFile(m_view);
        if (m_map) CloseHandle(m_map);
    }

    /// 最新フレームを dst にコピー。2 秒以上更新がなければ false (呼び出し側で待機画面を出す)
    bool Read(BYTE* dst)
    {
        if (!m_view) return false;
        auto hdr = reinterpret_cast<const CastMicCamHeader*>(m_view);
        for (int attempt = 0; attempt < 3; attempt++)
        {
            LONG s1 = hdr->seq;
            if (s1 & 1) { YieldProcessor(); continue; }
            MemoryBarrier();
            if (hdr->width != CASTMIC_CAM_WIDTH || hdr->height != CASTMIC_CAM_HEIGHT) return false;
            LARGE_INTEGER now; QueryPerformanceCounter(&now);
            if (hdr->updatedQpc == 0 || now.QuadPart - hdr->updatedQpc > 2 * m_freq.QuadPart) return false;
            memcpy(dst, m_view + sizeof(CastMicCamHeader), CASTMIC_CAM_NV12_SIZE);
            MemoryBarrier();
            if (hdr->seq == s1) return true;
        }
        return false;
    }

private:
    HANDLE m_map = nullptr;
    BYTE* m_view = nullptr;
    LARGE_INTEGER m_freq{};
};

// 映像が来ていないときの画面: 暗い灰色 + 中央に明るい横帯
static void FillWaiting(BYTE* nv12)
{
    const int w = CASTMIC_CAM_WIDTH, h = CASTMIC_CAM_HEIGHT;
    memset(nv12, 32, w * h);
    for (int y = h / 2 - 4; y < h / 2 + 4; y++) memset(nv12 + y * w + w / 4, 120, w / 2);
    memset(nv12 + w * h, 128, w * h / 2);
}

// ------------------------------------------------------------------ Stream

class Source;

class Stream : public RuntimeClass<RuntimeClassFlags<ClassicCom>, ChainInterfaces<IMFMediaStream2, IMFMediaStream, IMFMediaEventGenerator>>
{
public:
    HRESULT RuntimeClassInitialize(Source* source, IMFStreamDescriptor* sd);
    HRESULT Start();
    HRESULT Stop();
    void Shutdown();

    // IMFMediaEventGenerator
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* cb, IUnknown* state) override { return Q()->BeginGetEvent(cb, state); }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* r, IMFMediaEvent** e) override { return Q()->EndGetEvent(r, e); }
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** e) override { return Q()->GetEvent(flags, e); }
    STDMETHODIMP QueueEvent(MediaEventType t, REFGUID g, HRESULT s, const PROPVARIANT* v) override { return Q()->QueueEventParamVar(t, g, s, v); }

    // IMFMediaStream
    STDMETHODIMP GetMediaSource(IMFMediaSource** out) override;
    STDMETHODIMP GetStreamDescriptor(IMFStreamDescriptor** out) override;
    STDMETHODIMP RequestSample(IUnknown* token) override;

    // IMFMediaStream2
    STDMETHODIMP SetStreamState(MF_STREAM_STATE s) override;
    STDMETHODIMP GetStreamState(MF_STREAM_STATE* s) override;

private:
    IMFMediaEventQueue* Q() { return m_queue.Get(); }
    std::mutex m_lock;
    ComPtr<IMFMediaEventQueue> m_queue;
    ComPtr<IMFStreamDescriptor> m_sd;
    Source* m_source = nullptr;   // Source が Stream を所有する (循環参照を避ける)
    MF_STREAM_STATE m_state = MF_STREAM_STATE_STOPPED;
    FrameReader m_reader;
    LONGLONG m_frameIndex = 0;
};

// ------------------------------------------------------------------ Source

class Source : public RuntimeClass<RuntimeClassFlags<ClassicCom>, ChainInterfaces<IMFMediaSourceEx, IMFMediaSource, IMFMediaEventGenerator>, IKsControl>
{
public:
    HRESULT RuntimeClassInitialize()
    {
        RETURN_IF_FAILED(MFCreateEventQueue(&m_queue));
        RETURN_IF_FAILED(MFCreateAttributes(&m_attrs, 4));

        ComPtr<IMFMediaType> type;
        RETURN_IF_FAILED(MFCreateMediaType(&type));
        type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, CASTMIC_CAM_WIDTH, CASTMIC_CAM_HEIGHT);
        MFSetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, CASTMIC_CAM_FPS, 1);
        MFSetAttributeRatio(type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
        type->SetUINT32(MF_MT_DEFAULT_STRIDE, CASTMIC_CAM_WIDTH);
        type->SetUINT32(MF_MT_SAMPLE_SIZE, CASTMIC_CAM_NV12_SIZE);
        MFSetAttributeRatio(type.Get(), MF_MT_FRAME_RATE_RANGE_MAX, CASTMIC_CAM_FPS, 1);
        MFSetAttributeRatio(type.Get(), MF_MT_FRAME_RATE_RANGE_MIN, CASTMIC_CAM_FPS, 1);

        IMFMediaType* types[] = { type.Get() };
        ComPtr<IMFStreamDescriptor> sd;
        RETURN_IF_FAILED(MFCreateStreamDescriptor(0, 1, types, &sd));
        ComPtr<IMFMediaTypeHandler> handler;
        RETURN_IF_FAILED(sd->GetMediaTypeHandler(&handler));
        RETURN_IF_FAILED(handler->SetCurrentMediaType(type.Get()));
        sd->SetGUID(MF_DEVICESTREAM_STREAM_CATEGORY, PINNAME_VIDEO_CAPTURE);
        sd->SetUINT32(MF_DEVICESTREAM_STREAM_ID, 0);
        sd->SetUINT32(MF_DEVICESTREAM_FRAMESERVER_SHARED, 1);
        sd->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, MFFrameSourceTypes_Color);

        IMFStreamDescriptor* sds[] = { sd.Get() };
        RETURN_IF_FAILED(MFCreatePresentationDescriptor(1, sds, &m_pd));
        RETURN_IF_FAILED(m_pd->SelectStream(0));
        return MakeAndInitialize<Stream>(&m_stream, this, sd.Get());
    }

    // IMFMediaEventGenerator
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* cb, IUnknown* state) override { return m_queue->BeginGetEvent(cb, state); }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* r, IMFMediaEvent** e) override { return m_queue->EndGetEvent(r, e); }
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** e) override { return m_queue->GetEvent(flags, e); }
    STDMETHODIMP QueueEvent(MediaEventType t, REFGUID g, HRESULT s, const PROPVARIANT* v) override { return m_queue->QueueEventParamVar(t, g, s, v); }

    // IMFMediaSource
    STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** out) override
    {
        std::lock_guard<std::mutex> g(m_lock);
        if (m_shutdown) return MF_E_SHUTDOWN;
        return m_pd->Clone(out);
    }
    STDMETHODIMP GetCharacteristics(DWORD* out) override { *out = MFMEDIASOURCE_IS_LIVE; return S_OK; }
    STDMETHODIMP Pause() override { return MF_E_INVALID_STATE_TRANSITION; }

    STDMETHODIMP Start(IMFPresentationDescriptor* pd, const GUID* fmt, const PROPVARIANT* startPos) override
    {
        std::lock_guard<std::mutex> g(m_lock);
        if (m_shutdown) return MF_E_SHUTDOWN;
        if (!pd || !startPos) return E_INVALIDARG;
        if (fmt && *fmt != GUID_NULL) return MF_E_UNSUPPORTED_TIME_FORMAT;

        PROPVARIANT v; PropVariantInit(&v);
        v.vt = VT_UNKNOWN;
        v.punkVal = static_cast<IMFMediaStream2*>(m_stream.Get());
        RETURN_IF_FAILED(m_queue->QueueEventParamVar(m_started ? MEUpdatedStream : MENewStream, GUID_NULL, S_OK, &v));
        m_started = true;
        RETURN_IF_FAILED(m_stream->Start());

        PROPVARIANT t; PropVariantInit(&t);
        t.vt = VT_I8; t.hVal.QuadPart = MFGetSystemTime();
        return m_queue->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK, &t);
    }

    STDMETHODIMP Stop() override
    {
        std::lock_guard<std::mutex> g(m_lock);
        if (m_shutdown) return MF_E_SHUTDOWN;
        RETURN_IF_FAILED(m_stream->Stop());
        return m_queue->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, nullptr);
    }

    STDMETHODIMP Shutdown() override
    {
        std::lock_guard<std::mutex> g(m_lock);
        if (m_shutdown) return MF_E_SHUTDOWN;
        m_shutdown = true;
        m_stream->Shutdown();
        return m_queue->Shutdown();
    }

    // IMFMediaSourceEx
    STDMETHODIMP GetSourceAttributes(IMFAttributes** out) override { return m_attrs.CopyTo(out); }
    STDMETHODIMP GetStreamAttributes(DWORD id, IMFAttributes** out) override
    {
        if (id != 0) return MF_E_INVALIDSTREAMNUMBER;
        ComPtr<IMFStreamDescriptor> sd;
        RETURN_IF_FAILED(m_stream->GetStreamDescriptor(&sd));
        return sd.CopyTo(out);
    }
    STDMETHODIMP SetD3DManager(IUnknown*) override { return S_OK; }

    // IKsControl: カメラ制御 (露出など) は持たない
    STDMETHODIMP KsProperty(PKSPROPERTY, ULONG, LPVOID, ULONG, ULONG*) override { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }
    STDMETHODIMP KsMethod(PKSMETHOD, ULONG, LPVOID, ULONG, ULONG*) override { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }
    STDMETHODIMP KsEvent(PKSEVENT, ULONG, LPVOID, ULONG, ULONG*) override { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }

private:
    std::mutex m_lock;
    ComPtr<IMFMediaEventQueue> m_queue;
    ComPtr<IMFAttributes> m_attrs;
    ComPtr<IMFPresentationDescriptor> m_pd;
    ComPtr<Stream> m_stream;
    bool m_started = false;
    bool m_shutdown = false;
};

HRESULT Stream::RuntimeClassInitialize(Source* source, IMFStreamDescriptor* sd)
{
    m_source = source;
    m_sd = sd;
    m_reader.Open();
    return MFCreateEventQueue(&m_queue);
}

HRESULT Stream::Start()
{
    std::lock_guard<std::mutex> g(m_lock);
    m_state = MF_STREAM_STATE_RUNNING;
    return m_queue->QueueEventParamVar(MEStreamStarted, GUID_NULL, S_OK, nullptr);
}

HRESULT Stream::Stop()
{
    std::lock_guard<std::mutex> g(m_lock);
    m_state = MF_STREAM_STATE_STOPPED;
    return m_queue->QueueEventParamVar(MEStreamStopped, GUID_NULL, S_OK, nullptr);
}

void Stream::Shutdown()
{
    std::lock_guard<std::mutex> g(m_lock);
    if (m_queue) m_queue->Shutdown();
    m_source = nullptr;
}

STDMETHODIMP Stream::GetMediaSource(IMFMediaSource** out)
{
    std::lock_guard<std::mutex> g(m_lock);
    if (!m_source) return MF_E_SHUTDOWN;
    *out = static_cast<IMFMediaSourceEx*>(m_source);
    (*out)->AddRef();
    return S_OK;
}

STDMETHODIMP Stream::GetStreamDescriptor(IMFStreamDescriptor** out) { return m_sd.CopyTo(out); }

STDMETHODIMP Stream::RequestSample(IUnknown* token)
{
    std::lock_guard<std::mutex> g(m_lock);
    if (!m_source) return MF_E_SHUTDOWN;
    if (m_state != MF_STREAM_STATE_RUNNING) return MF_E_MEDIA_SOURCE_WRONGSTATE;

    ComPtr<IMFMediaBuffer> buf;
    RETURN_IF_FAILED(MFCreateMemoryBuffer(CASTMIC_CAM_NV12_SIZE, &buf));
    BYTE* p = nullptr;
    RETURN_IF_FAILED(buf->Lock(&p, nullptr, nullptr));
    if (!m_reader.Read(p)) FillWaiting(p);
    buf->Unlock();
    buf->SetCurrentLength(CASTMIC_CAM_NV12_SIZE);

    ComPtr<IMFSample> sample;
    RETURN_IF_FAILED(MFCreateSample(&sample));
    sample->AddBuffer(buf.Get());
    sample->SetSampleTime(MFGetSystemTime());
    sample->SetSampleDuration(10'000'000 / CASTMIC_CAM_FPS);
    m_frameIndex++;
    if (token) sample->SetUnknown(MFSampleExtension_Token, token);
    return m_queue->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample.Get());
}

STDMETHODIMP Stream::SetStreamState(MF_STREAM_STATE s)
{
    std::lock_guard<std::mutex> g(m_lock);
    m_state = s;
    return S_OK;
}

STDMETHODIMP Stream::GetStreamState(MF_STREAM_STATE* s)
{
    std::lock_guard<std::mutex> g(m_lock);
    *s = m_state;
    return S_OK;
}

// ------------------------------------------------------------------ Activator (Frame Server が CoCreateInstance する)

#define FWD(name, params, args) STDMETHODIMP name params override { return m_attrs->name args; }

class __declspec(uuid("3F2A6D41-9C7B-4E5A-8D21-6B0C4E7F9A13"))
Activator : public RuntimeClass<RuntimeClassFlags<ClassicCom>, ChainInterfaces<IMFActivate, IMFAttributes>>
{
public:
    HRESULT RuntimeClassInitialize() { return MFCreateAttributes(&m_attrs, 1); }

    STDMETHODIMP ActivateObject(REFIID riid, void** out) override
    {
        std::lock_guard<std::mutex> g(m_lock);
        if (!m_source) RETURN_IF_FAILED(MakeAndInitialize<Source>(&m_source));
        return m_source->QueryInterface(riid, out);
    }
    STDMETHODIMP ShutdownObject() override
    {
        std::lock_guard<std::mutex> g(m_lock);
        if (m_source) { m_source->Shutdown(); m_source.Reset(); }
        return S_OK;
    }
    STDMETHODIMP DetachObject() override
    {
        std::lock_guard<std::mutex> g(m_lock);
        m_source.Reset();
        return S_OK;
    }

    FWD(GetItem, (REFGUID k, PROPVARIANT* v), (k, v))
    FWD(GetItemType, (REFGUID k, MF_ATTRIBUTE_TYPE* t), (k, t))
    FWD(CompareItem, (REFGUID k, REFPROPVARIANT v, BOOL* r), (k, v, r))
    FWD(Compare, (IMFAttributes* a, MF_ATTRIBUTES_MATCH_TYPE t, BOOL* r), (a, t, r))
    FWD(GetUINT32, (REFGUID k, UINT32* v), (k, v))
    FWD(GetUINT64, (REFGUID k, UINT64* v), (k, v))
    FWD(GetDouble, (REFGUID k, double* v), (k, v))
    FWD(GetGUID, (REFGUID k, GUID* v), (k, v))
    FWD(GetStringLength, (REFGUID k, UINT32* v), (k, v))
    FWD(GetString, (REFGUID k, LPWSTR s, UINT32 n, UINT32* l), (k, s, n, l))
    FWD(GetAllocatedString, (REFGUID k, LPWSTR* s, UINT32* l), (k, s, l))
    FWD(GetBlobSize, (REFGUID k, UINT32* v), (k, v))
    FWD(GetBlob, (REFGUID k, UINT8* b, UINT32 n, UINT32* l), (k, b, n, l))
    FWD(GetAllocatedBlob, (REFGUID k, UINT8** b, UINT32* l), (k, b, l))
    FWD(GetUnknown, (REFGUID k, REFIID r, LPVOID* v), (k, r, v))
    FWD(SetItem, (REFGUID k, REFPROPVARIANT v), (k, v))
    FWD(DeleteItem, (REFGUID k), (k))
    FWD(DeleteAllItems, (), ())
    FWD(SetUINT32, (REFGUID k, UINT32 v), (k, v))
    FWD(SetUINT64, (REFGUID k, UINT64 v), (k, v))
    FWD(SetDouble, (REFGUID k, double v), (k, v))
    FWD(SetGUID, (REFGUID k, REFGUID v), (k, v))
    FWD(SetString, (REFGUID k, LPCWSTR v), (k, v))
    FWD(SetBlob, (REFGUID k, const UINT8* b, UINT32 n), (k, b, n))
    FWD(SetUnknown, (REFGUID k, IUnknown* v), (k, v))
    FWD(LockStore, (), ())
    FWD(UnlockStore, (), ())
    FWD(GetCount, (UINT32* n), (n))
    FWD(GetItemByIndex, (UINT32 i, GUID* k, PROPVARIANT* v), (i, k, v))
    FWD(CopyAllItems, (IMFAttributes* d), (d))

private:
    std::mutex m_lock;
    ComPtr<IMFAttributes> m_attrs;
    ComPtr<Source> m_source;
};

CoCreatableClass(Activator);

// ------------------------------------------------------------------ DLL エクスポート

static HMODULE g_module = nullptr;
static IMFVirtualCamera* g_vcam = nullptr;

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_module = inst;
        DisableThreadLibraryCalls(inst);
    }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, LPVOID* out)
{
    return Module<InProc>::GetModule().GetClassObject(clsid, riid, out);
}

STDAPI DllCanUnloadNow()
{
    return Module<InProc>::GetModule().Terminate() ? S_OK : S_FALSE;
}

static const wchar_t* ClsidKey() { return L"Software\\Classes\\CLSID\\{3F2A6D41-9C7B-4E5A-8D21-6B0C4E7F9A13}"; }

STDAPI DllRegisterServer()
{
    wchar_t path[MAX_PATH];
    if (!GetModuleFileNameW(g_module, path, MAX_PATH)) return HRESULT_FROM_WIN32(GetLastError());
    HKEY key;
    wchar_t sub[256];
    swprintf_s(sub, L"%s\\InprocServer32", ClsidKey());
    LSTATUS s = RegCreateKeyExW(HKEY_LOCAL_MACHINE, sub, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr);
    if (s != ERROR_SUCCESS) return HRESULT_FROM_WIN32(s);
    RegSetValueExW(key, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE*>(path), (DWORD)((wcslen(path) + 1) * sizeof(wchar_t)));
    const wchar_t model[] = L"Both";
    RegSetValueExW(key, L"ThreadingModel", 0, REG_SZ, reinterpret_cast<const BYTE*>(model), sizeof(model));
    RegCloseKey(key);
    return S_OK;
}

STDAPI DllUnregisterServer()
{
    LSTATUS s = RegDeleteTreeW(HKEY_LOCAL_MACHINE, ClsidKey());
    return s == ERROR_SUCCESS || s == ERROR_FILE_NOT_FOUND ? S_OK : HRESULT_FROM_WIN32(s);
}

/// CastMic.exe から呼ぶ: 仮想カメラ「CastMic Camera」を登録して開始 (このプロセスが終わるまで有効)
extern "C" HRESULT __stdcall CastMicCam_Start()
{
    if (g_vcam) return S_OK;
    RETURN_IF_FAILED(MFStartup(MF_VERSION));
    wchar_t clsid[64];
    StringFromGUID2(CLSID_CastMicCam, clsid, 64);
    HRESULT hr = MFCreateVirtualCamera(MFVirtualCameraType_SoftwareCameraSource, MFVirtualCameraLifetime_Session,
                                       MFVirtualCameraAccess_CurrentUser, L"CastMic Camera", clsid, nullptr, 0, &g_vcam);
    if (FAILED(hr)) return hr;
    hr = g_vcam->Start(nullptr);
    if (FAILED(hr)) { g_vcam->Release(); g_vcam = nullptr; }
    return hr;
}

extern "C" HRESULT __stdcall CastMicCam_Stop()
{
    if (!g_vcam) return S_OK;
    g_vcam->Shutdown();
    g_vcam->Release();
    g_vcam = nullptr;
    return S_OK;
}
