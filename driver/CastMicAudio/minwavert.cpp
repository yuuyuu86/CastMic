// WaveRT ミニポート: ハードウェアの代わりに高分解能タイマーで DMA バッファを進め、
// render はリングバッファ g_SpkRing へ吸い出し、capture は g_MicRing から書き込む。
#include "common.h"

// ---------------------------------------------------------------- フィルタ記述子

static KSDATARANGE_AUDIO SpeakerStreamRange =
{
    { sizeof(KSDATARANGE_AUDIO), 0, 0, 0,
      STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
      STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM),
      STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX) },
    CASTMIC_SPK_CH, CASTMIC_BITS, CASTMIC_BITS, CASTMIC_SAMPLE_RATE, CASTMIC_SAMPLE_RATE
};

static KSDATARANGE_AUDIO MicStreamRange =
{
    { sizeof(KSDATARANGE_AUDIO), 0, 0, 0,
      STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
      STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM),
      STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX) },
    CASTMIC_MIC_CH, CASTMIC_BITS, CASTMIC_BITS, CASTMIC_SAMPLE_RATE, CASTMIC_SAMPLE_RATE
};

static KSDATARANGE BridgeRange =
{
    sizeof(KSDATARANGE), 0, 0, 0,
    STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
    STATICGUIDOF(KSDATAFORMAT_SUBTYPE_ANALOG),
    STATICGUIDOF(KSDATAFORMAT_SPECIFIER_NONE)
};

static PKSDATARANGE SpeakerStreamRanges[] = { PKSDATARANGE(&SpeakerStreamRange) };
static PKSDATARANGE MicStreamRanges[]     = { PKSDATARANGE(&MicStreamRange) };
static PKSDATARANGE BridgeRanges[]        = { &BridgeRange };

static PCPIN_DESCRIPTOR SpeakerWavePins[] =
{
    // 0: ストリーム (オーディオエンジンが書き込む)
    { 1, 1, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(SpeakerStreamRanges), SpeakerStreamRanges,
        KSPIN_DATAFLOW_IN, KSPIN_COMMUNICATION_SINK, &KSCATEGORY_AUDIO, NULL, 0 } },
    // 1: トポロジーフィルタへのブリッジ
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(BridgeRanges), BridgeRanges,
        KSPIN_DATAFLOW_OUT, KSPIN_COMMUNICATION_NONE, &KSCATEGORY_AUDIO, NULL, 0 } },
};

static PCPIN_DESCRIPTOR MicWavePins[] =
{
    // 0: トポロジーフィルタからのブリッジ
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(BridgeRanges), BridgeRanges,
        KSPIN_DATAFLOW_IN, KSPIN_COMMUNICATION_NONE, &KSCATEGORY_AUDIO, NULL, 0 } },
    // 1: ストリーム (オーディオエンジンが読み出す)
    { 1, 1, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(MicStreamRanges), MicStreamRanges,
        KSPIN_DATAFLOW_OUT, KSPIN_COMMUNICATION_SINK, &KSCATEGORY_AUDIO, &KSAUDFNAME_RECORDING_CONTROL, 0 } },
};

static PCCONNECTION_DESCRIPTOR WaveConnections[] =
{
    { PCFILTER_NODE, 0, PCFILTER_NODE, 1 },
};

static GUID SpeakerWaveCategories[] =
{
    STATICGUIDOF(KSCATEGORY_AUDIO), STATICGUIDOF(KSCATEGORY_RENDER), STATICGUIDOF(KSCATEGORY_REALTIME)
};

static GUID MicWaveCategories[] =
{
    STATICGUIDOF(KSCATEGORY_AUDIO), STATICGUIDOF(KSCATEGORY_CAPTURE), STATICGUIDOF(KSCATEGORY_REALTIME)
};

static PCFILTER_DESCRIPTOR SpeakerWaveFilter =
{
    0, NULL,
    sizeof(PCPIN_DESCRIPTOR), SIZEOF_ARRAY(SpeakerWavePins), SpeakerWavePins,
    sizeof(PCNODE_DESCRIPTOR), 0, NULL,
    SIZEOF_ARRAY(WaveConnections), WaveConnections,
    SIZEOF_ARRAY(SpeakerWaveCategories), SpeakerWaveCategories
};

static PCFILTER_DESCRIPTOR MicWaveFilter =
{
    0, NULL,
    sizeof(PCPIN_DESCRIPTOR), SIZEOF_ARRAY(MicWavePins), MicWavePins,
    sizeof(PCNODE_DESCRIPTOR), 0, NULL,
    SIZEOF_ARRAY(WaveConnections), WaveConnections,
    SIZEOF_ARRAY(MicWaveCategories), MicWaveCategories
};

// ---------------------------------------------------------------- クラス定義

class CMiniportWaveRT : public IMiniportWaveRT, public CUnknown
{
public:
    DECLARE_STD_UNKNOWN();
    DEFINE_STD_CONSTRUCTOR(CMiniportWaveRT);
    ~CMiniportWaveRT();
    IMP_IMiniportWaveRT;

    BOOLEAN     m_Capture = FALSE;
    PPORTWAVERT m_Port = NULL;
};

class CMiniportWaveRTStream : public IMiniportWaveRTStream, public CUnknown
{
public:
    DECLARE_STD_UNKNOWN();
    DEFINE_STD_CONSTRUCTOR(CMiniportWaveRTStream);
    ~CMiniportWaveRTStream();
    IMP_IMiniportWaveRTStream;

    NTSTATUS Init(BOOLEAN Capture, PPORTWAVERTSTREAM PortStream);

private:
    static VOID TimerCallback(PEX_TIMER Timer, PVOID Context);
    void Advance(); // m_Lock 保持中に呼ぶ

    BOOLEAN           m_Capture = FALSE;
    ULONG             m_BlockAlign = 0;
    PPORTWAVERTSTREAM m_PortStream = NULL;
    PMDL              m_Mdl = NULL;
    PUCHAR            m_Buffer = NULL;
    ULONG             m_BufferSize = 0;
    KSSTATE           m_State = KSSTATE_STOP;
    PEX_TIMER         m_Timer = NULL;
    KSPIN_LOCK        m_Lock;
    LONGLONG          m_Freq = 0;
    LONGLONG          m_LastQpc = 0;
    LONGLONG          m_Remainder = 0;
    ULONGLONG         m_Position = 0;   // 累積バイト数
};

// ---------------------------------------------------------------- CMiniportWaveRT

NTSTATUS CreateMiniportWaveRT(PUNKNOWN* Unknown, BOOLEAN Capture)
{
    auto* obj = new (POOL_FLAG_NON_PAGED, CASTMIC_POOLTAG) CMiniportWaveRT(NULL);
    if (!obj) return STATUS_INSUFFICIENT_RESOURCES;
    obj->m_Capture = Capture;
    *Unknown = PUNKNOWN(PMINIPORTWAVERT(obj));
    (*Unknown)->AddRef();
    return STATUS_SUCCESS;
}

CMiniportWaveRT::~CMiniportWaveRT()
{
    if (m_Port) m_Port->Release();
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::NonDelegatingQueryInterface(REFIID Interface, PVOID* Object)
{
    if (IsEqualGUIDAligned(Interface, IID_IUnknown))
        *Object = PVOID(PUNKNOWN(PMINIPORTWAVERT(this)));
    else if (IsEqualGUIDAligned(Interface, IID_IMiniport))
        *Object = PVOID(PMINIPORT(this));
    else if (IsEqualGUIDAligned(Interface, IID_IMiniportWaveRT))
        *Object = PVOID(PMINIPORTWAVERT(this));
    else
    {
        *Object = NULL;
        return STATUS_INVALID_PARAMETER;
    }
    PUNKNOWN(*Object)->AddRef();
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::Init(PUNKNOWN UnknownAdapter, PRESOURCELIST ResourceList, PPORTWAVERT Port)
{
    UNREFERENCED_PARAMETER(UnknownAdapter);
    UNREFERENCED_PARAMETER(ResourceList);
    m_Port = Port;
    m_Port->AddRef();
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::GetDescription(PPCFILTER_DESCRIPTOR* OutFilterDescriptor)
{
    *OutFilterDescriptor = m_Capture ? &MicWaveFilter : &SpeakerWaveFilter;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::DataRangeIntersection(
    ULONG, PKSDATARANGE, PKSDATARANGE, ULONG, PVOID, PULONG)
{
    return STATUS_NOT_IMPLEMENTED; // PortCls の既定処理に任せる
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::GetDeviceDescription(PDEVICE_DESCRIPTION DeviceDescription)
{
    RtlZeroMemory(DeviceDescription, sizeof(DEVICE_DESCRIPTION));
    DeviceDescription->Master = TRUE;
    DeviceDescription->ScatterGather = TRUE;
    DeviceDescription->Dma32BitAddresses = TRUE;
    DeviceDescription->InterfaceType = PCIBus;
    DeviceDescription->MaximumLength = 0xFFFFFFFF;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::NewStream(
    PMINIPORTWAVERTSTREAM* OutStream, PPORTWAVERTSTREAM PortStream,
    ULONG Pin, BOOLEAN Capture, PKSDATAFORMAT DataFormat)
{
    *OutStream = NULL;
    ULONG streamPin = m_Capture ? 1 : 0;
    if (Pin != streamPin || Capture != m_Capture) return STATUS_INVALID_PARAMETER;

    if (DataFormat->FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEX)) return STATUS_NO_MATCH;
    PWAVEFORMATEX wfx = &PKSDATAFORMAT_WAVEFORMATEX(DataFormat)->WaveFormatEx;
    if (wfx->nSamplesPerSec != CASTMIC_SAMPLE_RATE ||
        wfx->wBitsPerSample != CASTMIC_BITS ||
        wfx->nChannels != (m_Capture ? CASTMIC_MIC_CH : CASTMIC_SPK_CH))
        return STATUS_NO_MATCH;

    auto* stream = new (POOL_FLAG_NON_PAGED, CASTMIC_POOLTAG) CMiniportWaveRTStream(NULL);
    if (!stream) return STATUS_INSUFFICIENT_RESOURCES;
    stream->AddRef();
    NTSTATUS status = stream->Init(Capture, PortStream);
    if (!NT_SUCCESS(status))
    {
        stream->Release();
        return status;
    }
    *OutStream = PMINIPORTWAVERTSTREAM(stream);
    return STATUS_SUCCESS;
}

// ---------------------------------------------------------------- CMiniportWaveRTStream

NTSTATUS CMiniportWaveRTStream::Init(BOOLEAN Capture, PPORTWAVERTSTREAM PortStream)
{
    m_Capture = Capture;
    m_BlockAlign = Capture ? MIC_BLOCK_ALIGN : SPK_BLOCK_ALIGN;
    m_PortStream = PortStream;
    m_PortStream->AddRef();
    KeInitializeSpinLock(&m_Lock);

    LARGE_INTEGER freq;
    KeQueryPerformanceCounter(&freq);
    m_Freq = freq.QuadPart;

    m_Timer = ExAllocateTimer(TimerCallback, this, EX_TIMER_HIGH_RESOLUTION);
    if (!m_Timer) return STATUS_INSUFFICIENT_RESOURCES;

    if (Capture) g_MicRing.Clear();
    return STATUS_SUCCESS;
}

CMiniportWaveRTStream::~CMiniportWaveRTStream()
{
    if (m_Timer)
    {
        ExDeleteTimer(m_Timer, TRUE, TRUE, NULL); // キャンセルしてコールバック完了を待つ
        m_Timer = NULL;
    }
    if (m_Mdl) FreeAudioBuffer(m_Mdl, m_BufferSize);
    if (m_PortStream) m_PortStream->Release();
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::NonDelegatingQueryInterface(REFIID Interface, PVOID* Object)
{
    if (IsEqualGUIDAligned(Interface, IID_IUnknown))
        *Object = PVOID(PUNKNOWN(PMINIPORTWAVERTSTREAM(this)));
    else if (IsEqualGUIDAligned(Interface, IID_IMiniportWaveRTStream))
        *Object = PVOID(PMINIPORTWAVERTSTREAM(this));
    else
    {
        *Object = NULL;
        return STATUS_INVALID_PARAMETER;
    }
    PUNKNOWN(*Object)->AddRef();
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::AllocateAudioBuffer(
    ULONG RequestedSize, PMDL* AudioBufferMdl, ULONG* ActualSize,
    ULONG* OffsetFromFirstPage, MEMORY_CACHING_TYPE* CacheType)
{
    ULONG size = RequestedSize - RequestedSize % m_BlockAlign;
    if (size == 0) size = m_BlockAlign * (CASTMIC_SAMPLE_RATE / 100); // 10ms

    PHYSICAL_ADDRESS high;
    high.QuadPart = MAXLONGLONG;
    PMDL mdl = m_PortStream->AllocatePagesForMdl(high, size);
    if (!mdl) return STATUS_INSUFFICIENT_RESOURCES;

    PVOID va = m_PortStream->MapAllocatedPages(mdl, MmCached);
    if (!va)
    {
        m_PortStream->FreePagesFromMdl(mdl);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    RtlZeroMemory(va, size);

    m_Mdl = mdl;
    m_Buffer = PUCHAR(va);
    m_BufferSize = size;

    *AudioBufferMdl = mdl;
    *ActualSize = size;
    *OffsetFromFirstPage = 0;
    *CacheType = MmCached;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(VOID) CMiniportWaveRTStream::FreeAudioBuffer(PMDL AudioBufferMdl, ULONG BufferSize)
{
    UNREFERENCED_PARAMETER(BufferSize);
    if (!AudioBufferMdl) return;
    KIRQL irql;
    KeAcquireSpinLock(&m_Lock, &irql);
    PUCHAR buffer = m_Buffer;
    m_Buffer = NULL;
    m_BufferSize = 0;
    m_Mdl = NULL;
    KeReleaseSpinLock(&m_Lock, irql);

    if (buffer) m_PortStream->UnmapAllocatedPages(buffer, AudioBufferMdl);
    m_PortStream->FreePagesFromMdl(AudioBufferMdl);
}

STDMETHODIMP_(VOID) CMiniportWaveRTStream::GetHWLatency(PKSRTAUDIO_HWLATENCY hwLatency)
{
    hwLatency->FifoSize = 0;
    hwLatency->ChipsetDelay = 0;
    hwLatency->CodecDelay = 0;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::GetPositionRegister(PKSRTAUDIO_HWREGISTER)
{
    return STATUS_NOT_SUPPORTED;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::GetClockRegister(PKSRTAUDIO_HWREGISTER)
{
    return STATUS_NOT_SUPPORTED;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::SetFormat(PKSDATAFORMAT)
{
    return STATUS_NOT_SUPPORTED; // フォーマットは固定
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::SetState(KSSTATE State)
{
    KIRQL irql;
    switch (State)
    {
    case KSSTATE_RUN:
        if (m_State != KSSTATE_RUN)
        {
            KeAcquireSpinLock(&m_Lock, &irql);
            m_LastQpc = KeQueryPerformanceCounter(NULL).QuadPart;
            m_Remainder = 0;
            m_State = KSSTATE_RUN;
            KeReleaseSpinLock(&m_Lock, irql);
            ExSetTimer(m_Timer, -100000LL /*10ms*/, 100000LL /*10ms*/, NULL);
        }
        break;

    case KSSTATE_PAUSE:
        if (m_State == KSSTATE_RUN)
        {
            ExCancelTimer(m_Timer, NULL);
            KeAcquireSpinLock(&m_Lock, &irql);
            Advance();
            m_State = KSSTATE_PAUSE;
            KeReleaseSpinLock(&m_Lock, irql);
        }
        else
        {
            m_State = KSSTATE_PAUSE;
        }
        break;

    case KSSTATE_ACQUIRE:
    case KSSTATE_STOP:
        ExCancelTimer(m_Timer, NULL);
        KeAcquireSpinLock(&m_Lock, &irql);
        if (State == KSSTATE_STOP)
        {
            m_Position = 0;
            m_Remainder = 0;
        }
        m_State = State;
        KeReleaseSpinLock(&m_Lock, irql);
        break;
    }
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::GetPosition(PKSAUDIO_POSITION Position)
{
    KIRQL irql;
    KeAcquireSpinLock(&m_Lock, &irql);
    if (m_State == KSSTATE_RUN) Advance();
    ULONG offset = m_BufferSize ? ULONG(m_Position % m_BufferSize) : 0;
    KeReleaseSpinLock(&m_Lock, irql);

    Position->PlayOffset = offset;
    Position->WriteOffset = offset;
    return STATUS_SUCCESS;
}

VOID CMiniportWaveRTStream::TimerCallback(PEX_TIMER Timer, PVOID Context)
{
    UNREFERENCED_PARAMETER(Timer);
    auto* self = static_cast<CMiniportWaveRTStream*>(Context);
    KIRQL irql;
    KeAcquireSpinLock(&self->m_Lock, &irql);
    if (self->m_State == KSSTATE_RUN) self->Advance();
    KeReleaseSpinLock(&self->m_Lock, irql);
}

void CMiniportWaveRTStream::Advance()
{
    LONGLONG now = KeQueryPerformanceCounter(NULL).QuadPart;
    LONGLONG num = (now - m_LastQpc) * CASTMIC_SAMPLE_RATE + m_Remainder;
    m_LastQpc = now;
    LONGLONG frames = num / m_Freq;
    m_Remainder = num % m_Freq;

    if (!m_Buffer || m_BufferSize == 0 || frames <= 0) return;

    ULONGLONG bytes64 = ULONGLONG(frames) * m_BlockAlign;
    ULONG bytes = bytes64 > m_BufferSize ? m_BufferSize : ULONG(bytes64); // 長時間止まった場合
    ULONG offset = ULONG(m_Position % m_BufferSize);

    while (bytes)
    {
        ULONG chunk = min(bytes, m_BufferSize - offset);
        if (m_Capture)
        {
            ULONG got = g_MicRing.Read(m_Buffer + offset, chunk);
            if (got < chunk) RtlZeroMemory(m_Buffer + offset + got, chunk - got); // 足りない分は無音
        }
        else
        {
            g_SpkRing.Write(m_Buffer + offset, chunk);
        }
        offset = (offset + chunk) % m_BufferSize;
        m_Position += chunk;
        bytes -= chunk;
    }
}
