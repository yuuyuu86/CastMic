#include "common.h"

// 200ms ぶんのバッファ (グローバル変数は非ページプール)
static UCHAR s_MicData[CASTMIC_SAMPLE_RATE / 5 * MIC_BLOCK_ALIGN];
static UCHAR s_SpkData[CASTMIC_SAMPLE_RATE / 5 * SPK_BLOCK_ALIGN];
RingBuffer g_MicRing;
RingBuffer g_SpkRing;

static PDEVICE_OBJECT g_ControlDevice = NULL;

// {6B1C5B3E-2F4A-4C61-9D0B-4F2C1A7E9C11}
static const GUID GUID_CastMicControlClass =
    { 0x6b1c5b3e, 0x2f4a, 0x4c61, { 0x9d, 0x0b, 0x4f, 0x2c, 0x1a, 0x7e, 0x9c, 0x11 } };

NTSTATUS CreateControlDevice(PDRIVER_OBJECT DriverObject)
{
    g_MicRing.Init(s_MicData, sizeof(s_MicData));
    g_SpkRing.Init(s_SpkData, sizeof(s_SpkData));

    UNICODE_STRING name, link;
    RtlInitUnicodeString(&name, CASTMIC_DEVICE_NAME);
    RtlInitUnicodeString(&link, CASTMIC_DOS_DEVICE_NAME);

    // 一般ユーザーの CastMic.exe から開けるよう Everyone に RW を与える
    NTSTATUS status = IoCreateDeviceSecure(
        DriverObject, 0, &name, FILE_DEVICE_UNKNOWN, FILE_DEVICE_SECURE_OPEN, FALSE,
        &SDDL_DEVOBJ_SYS_ALL_ADM_RWX_WORLD_RW_RES_R, &GUID_CastMicControlClass, &g_ControlDevice);
    if (!NT_SUCCESS(status)) return status;

    status = IoCreateSymbolicLink(&link, &name);
    if (!NT_SUCCESS(status))
    {
        IoDeleteDevice(g_ControlDevice);
        g_ControlDevice = NULL;
        return status;
    }
    g_ControlDevice->Flags |= DO_BUFFERED_IO;
    g_ControlDevice->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}

void DeleteControlDevice()
{
    if (!g_ControlDevice) return;
    UNICODE_STRING link;
    RtlInitUnicodeString(&link, CASTMIC_DOS_DEVICE_NAME);
    IoDeleteSymbolicLink(&link);
    IoDeleteDevice(g_ControlDevice);
    g_ControlDevice = NULL;
}

BOOLEAN IsControlDevice(PDEVICE_OBJECT DeviceObject)
{
    return g_ControlDevice != NULL && DeviceObject == g_ControlDevice;
}

NTSTATUS DispatchControlDevice(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS status = STATUS_SUCCESS;
    ULONG_PTR info = 0;

    switch (sp->MajorFunction)
    {
    case IRP_MJ_CREATE:
    case IRP_MJ_CLOSE:
    case IRP_MJ_CLEANUP:
        break;

    case IRP_MJ_DEVICE_CONTROL:
    {
        PUCHAR buf = (PUCHAR)Irp->AssociatedIrp.SystemBuffer;
        ULONG inLen = sp->Parameters.DeviceIoControl.InputBufferLength;
        ULONG outLen = sp->Parameters.DeviceIoControl.OutputBufferLength;
        switch (sp->Parameters.DeviceIoControl.IoControlCode)
        {
        case IOCTL_CASTMIC_WRITE_MIC:
            inLen -= inLen % MIC_BLOCK_ALIGN;
            if (inLen && buf) g_MicRing.Write(buf, inLen);
            break;
        case IOCTL_CASTMIC_READ_SPEAKER:
            outLen -= outLen % SPK_BLOCK_ALIGN;
            if (outLen && buf) info = g_SpkRing.Read(buf, outLen);
            break;
        default:
            status = STATUS_INVALID_DEVICE_REQUEST;
        }
        break;
    }

    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
    }

    Irp->IoStatus.Status = status;
    Irp->IoStatus.Information = info;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}
