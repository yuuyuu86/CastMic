// ドライバエントリ / PnP 開始処理 / IRP ディスパッチの振り分け
// portcls / ksmedia の GUID 実体をこの翻訳単位で定義する
#define PUT_GUIDS_HERE
#include "common.h"

extern "C" DRIVER_INITIALIZE DriverEntry;
static DRIVER_ADD_DEVICE AddDevice;
static DRIVER_UNLOAD DriverUnload;
static DRIVER_DISPATCH DispatchHook;

static PDRIVER_DISPATCH g_PcDispatch[IRP_MJ_MAXIMUM_FUNCTION + 1];
static PDRIVER_UNLOAD   g_PcUnload = NULL;

#define MAX_MINIPORTS 4

static NTSTATUS InstallSubdevice(
    PDEVICE_OBJECT DeviceObject, PIRP Irp, PCWSTR Name, REFGUID PortClass,
    PUNKNOWN Miniport, PRESOURCELIST ResourceList, PUNKNOWN* OutPort)
{
    PPORT port = NULL;
    NTSTATUS status = PcNewPort(&port, PortClass);
    if (!NT_SUCCESS(status)) return status;

    status = port->Init(DeviceObject, Irp, Miniport, NULL, ResourceList);
    if (NT_SUCCESS(status))
        status = PcRegisterSubdevice(DeviceObject, const_cast<PWSTR>(Name), port);

    if (!NT_SUCCESS(status))
    {
        port->Release();
        return status;
    }
    *OutPort = port; // 呼び出し側が Release する
    return STATUS_SUCCESS;
}

// wave + topology の組を登録して物理接続する
static NTSTATUS InstallEndpoint(PDEVICE_OBJECT DeviceObject, PIRP Irp, PRESOURCELIST ResourceList, BOOLEAN Capture)
{
    PUNKNOWN waveMp = NULL, topoMp = NULL, wavePort = NULL, topoPort = NULL;
    NTSTATUS status = CreateMiniportWaveRT(&waveMp, Capture);
    if (NT_SUCCESS(status)) status = CreateMiniportTopology(&topoMp, Capture);

    if (NT_SUCCESS(status))
        status = InstallSubdevice(DeviceObject, Irp, Capture ? L"TopologyMic" : L"TopologySpeaker",
                                  CLSID_PortTopology, topoMp, ResourceList, &topoPort);
    if (NT_SUCCESS(status))
        status = InstallSubdevice(DeviceObject, Irp, Capture ? L"WaveMic" : L"WaveSpeaker",
                                  CLSID_PortWaveRT, waveMp, ResourceList, &wavePort);

    if (NT_SUCCESS(status))
    {
        if (Capture) // topology pin1 (bridge out) -> wave pin0 (bridge in)
            status = PcRegisterPhysicalConnection(DeviceObject, topoPort, 1, wavePort, 0);
        else         // wave pin1 (bridge out) -> topology pin0 (bridge in)
            status = PcRegisterPhysicalConnection(DeviceObject, wavePort, 1, topoPort, 0);
    }

    if (waveMp) waveMp->Release();
    if (topoMp) topoMp->Release();
    if (wavePort) wavePort->Release();
    if (topoPort) topoPort->Release();
    return status;
}

static NTSTATUS StartDevice(PDEVICE_OBJECT DeviceObject, PIRP Irp, PRESOURCELIST ResourceList)
{
    NTSTATUS status = InstallEndpoint(DeviceObject, Irp, ResourceList, FALSE);
    if (NT_SUCCESS(status)) status = InstallEndpoint(DeviceObject, Irp, ResourceList, TRUE);
    return status;
}

static NTSTATUS AddDevice(PDRIVER_OBJECT DriverObject, PDEVICE_OBJECT PhysicalDeviceObject)
{
    return PcAddAdapterDevice(DriverObject, PhysicalDeviceObject, PCPFNSTARTDEVICE(StartDevice), MAX_MINIPORTS, 0);
}

// コントロールデバイス宛ての IRP だけ自前で処理し、残りは PortCls に渡す
static NTSTATUS DispatchHook(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    if (IsControlDevice(DeviceObject)) return DispatchControlDevice(DeviceObject, Irp);
    UCHAR mj = IoGetCurrentIrpStackLocation(Irp)->MajorFunction;
    return g_PcDispatch[mj](DeviceObject, Irp);
}

static VOID DriverUnload(PDRIVER_OBJECT DriverObject)
{
    DeleteControlDevice();
    if (g_PcUnload) g_PcUnload(DriverObject);
}

extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    NTSTATUS status = PcInitializeAdapterDriver(DriverObject, RegistryPath, PDRIVER_ADD_DEVICE(AddDevice));
    if (!NT_SUCCESS(status)) return status;

    status = CreateControlDevice(DriverObject);
    if (!NT_SUCCESS(status)) return status;

    const UCHAR hooked[] = { IRP_MJ_CREATE, IRP_MJ_CLOSE, IRP_MJ_CLEANUP, IRP_MJ_DEVICE_CONTROL };
    for (UCHAR mj : hooked)
    {
        g_PcDispatch[mj] = DriverObject->MajorFunction[mj];
        DriverObject->MajorFunction[mj] = DispatchHook;
    }
    g_PcUnload = DriverObject->DriverUnload;
    DriverObject->DriverUnload = DriverUnload;
    return STATUS_SUCCESS;
}
