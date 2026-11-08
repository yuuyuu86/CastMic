// トポロジーミニポート: 物理ピンのカテゴリ (スピーカー / マイク) で endpoint の種類を決めるだけの最小構成
#include "common.h"

static KSDATARANGE TopoBridgeRange =
{
    sizeof(KSDATARANGE), 0, 0, 0,
    STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
    STATICGUIDOF(KSDATAFORMAT_SUBTYPE_ANALOG),
    STATICGUIDOF(KSDATAFORMAT_SPECIFIER_NONE)
};
static PKSDATARANGE TopoRanges[] = { &TopoBridgeRange };

static PCPIN_DESCRIPTOR SpeakerTopoPins[] =
{
    // 0: wave フィルタからのブリッジ
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(TopoRanges), TopoRanges,
        KSPIN_DATAFLOW_IN, KSPIN_COMMUNICATION_NONE, &KSCATEGORY_AUDIO, NULL, 0 } },
    // 1: 物理出力 (スピーカー)
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(TopoRanges), TopoRanges,
        KSPIN_DATAFLOW_OUT, KSPIN_COMMUNICATION_NONE, &KSNODETYPE_SPEAKER, NULL, 0 } },
};

static PCPIN_DESCRIPTOR MicTopoPins[] =
{
    // 0: 物理入力 (マイク)
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(TopoRanges), TopoRanges,
        KSPIN_DATAFLOW_IN, KSPIN_COMMUNICATION_NONE, &KSNODETYPE_MICROPHONE, NULL, 0 } },
    // 1: wave フィルタへのブリッジ
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(TopoRanges), TopoRanges,
        KSPIN_DATAFLOW_OUT, KSPIN_COMMUNICATION_NONE, &KSCATEGORY_AUDIO, NULL, 0 } },
};

static PCCONNECTION_DESCRIPTOR TopoConnections[] =
{
    { PCFILTER_NODE, 0, PCFILTER_NODE, 1 },
};

static GUID TopoCategories[] =
{
    STATICGUIDOF(KSCATEGORY_AUDIO), STATICGUIDOF(KSCATEGORY_TOPOLOGY)
};

static PCFILTER_DESCRIPTOR SpeakerTopoFilter =
{
    0, NULL,
    sizeof(PCPIN_DESCRIPTOR), SIZEOF_ARRAY(SpeakerTopoPins), SpeakerTopoPins,
    sizeof(PCNODE_DESCRIPTOR), 0, NULL,
    SIZEOF_ARRAY(TopoConnections), TopoConnections,
    SIZEOF_ARRAY(TopoCategories), TopoCategories
};

static PCFILTER_DESCRIPTOR MicTopoFilter =
{
    0, NULL,
    sizeof(PCPIN_DESCRIPTOR), SIZEOF_ARRAY(MicTopoPins), MicTopoPins,
    sizeof(PCNODE_DESCRIPTOR), 0, NULL,
    SIZEOF_ARRAY(TopoConnections), TopoConnections,
    SIZEOF_ARRAY(TopoCategories), TopoCategories
};

class CMiniportTopology : public IMiniportTopology, public CUnknown
{
public:
    DECLARE_STD_UNKNOWN();
    DEFINE_STD_CONSTRUCTOR(CMiniportTopology);
    ~CMiniportTopology() {}
    IMP_IMiniportTopology;

    BOOLEAN m_Capture = FALSE;
};

NTSTATUS CreateMiniportTopology(PUNKNOWN* Unknown, BOOLEAN Capture)
{
    auto* obj = new (POOL_FLAG_NON_PAGED, CASTMIC_POOLTAG) CMiniportTopology(NULL);
    if (!obj) return STATUS_INSUFFICIENT_RESOURCES;
    obj->m_Capture = Capture;
    *Unknown = PUNKNOWN(PMINIPORTTOPOLOGY(obj));
    (*Unknown)->AddRef();
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportTopology::NonDelegatingQueryInterface(REFIID Interface, PVOID* Object)
{
    if (IsEqualGUIDAligned(Interface, IID_IUnknown))
        *Object = PVOID(PUNKNOWN(PMINIPORTTOPOLOGY(this)));
    else if (IsEqualGUIDAligned(Interface, IID_IMiniport))
        *Object = PVOID(PMINIPORT(this));
    else if (IsEqualGUIDAligned(Interface, IID_IMiniportTopology))
        *Object = PVOID(PMINIPORTTOPOLOGY(this));
    else
    {
        *Object = NULL;
        return STATUS_INVALID_PARAMETER;
    }
    PUNKNOWN(*Object)->AddRef();
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportTopology::Init(PUNKNOWN, PRESOURCELIST, PPORTTOPOLOGY)
{
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportTopology::GetDescription(PPCFILTER_DESCRIPTOR* OutFilterDescriptor)
{
    *OutFilterDescriptor = m_Capture ? &MicTopoFilter : &SpeakerTopoFilter;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportTopology::DataRangeIntersection(
    ULONG, PKSDATARANGE, PKSDATARANGE, ULONG, PVOID, PULONG)
{
    return STATUS_NOT_IMPLEMENTED;
}
