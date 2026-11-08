using System.ComponentModel;
using System.Runtime.InteropServices;

namespace CastMic;

/// devcon install / remove 相当 (Root\CastMicAudio を作成してドライバを入れる)。管理者権限で実行すること。
public static class DriverInstaller
{
    const string HardwareId = @"Root\CastMicAudio";
    const int DICD_GENERATE_ID = 0x1;
    const uint DIF_REGISTERDEVICE = 0x19, DIF_REMOVE = 0x05;
    const uint SPDRP_HARDWAREID = 0x1;
    const uint DIGCF_ALLCLASSES = 0x4;
    const uint INSTALLFLAG_FORCE = 0x1;
    const int ERROR_NO_SUCH_DEVINST = unchecked((int)0xE000020B);

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA
    {
        public int cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    public static int Install(string infPath)
    {
        infPath = Path.GetFullPath(infPath);
        // 既にデバイスがあればドライバ更新だけ
        if (UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, HardwareId, infPath, INSTALLFLAG_FORCE, out _)) return 0;
        var err = Marshal.GetLastWin32Error();
        if (err != ERROR_NO_SUCH_DEVINST) throw new Win32Exception(err);

        var className = new char[256];
        if (!SetupDiGetINFClass(infPath, out var classGuid, className, className.Length, IntPtr.Zero)) throw new Win32Exception();
        var set = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (set == new IntPtr(-1)) throw new Win32Exception();
        try
        {
            var data = new SP_DEVINFO_DATA { cbSize = Marshal.SizeOf<SP_DEVINFO_DATA>() };
            var name = new string(className).TrimEnd('\0');
            if (!SetupDiCreateDeviceInfo(set, name, ref classGuid, null, IntPtr.Zero, DICD_GENERATE_ID, ref data)) throw new Win32Exception();
            var ids = System.Text.Encoding.Unicode.GetBytes(HardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(set, ref data, SPDRP_HARDWAREID, ids, ids.Length)) throw new Win32Exception();
            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, ref data)) throw new Win32Exception();
        }
        finally { SetupDiDestroyDeviceInfoList(set); }

        if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, HardwareId, infPath, INSTALLFLAG_FORCE, out _)) throw new Win32Exception();
        return 0;
    }

    public static int Remove()
    {
        var set = SetupDiGetClassDevs(IntPtr.Zero, null, IntPtr.Zero, DIGCF_ALLCLASSES);
        if (set == new IntPtr(-1)) throw new Win32Exception();
        int removed = 0;
        try
        {
            var data = new SP_DEVINFO_DATA { cbSize = Marshal.SizeOf<SP_DEVINFO_DATA>() };
            var buf = new byte[1024];
            for (uint i = 0; SetupDiEnumDeviceInfo(set, i, ref data); i++)
            {
                if (!SetupDiGetDeviceRegistryProperty(set, ref data, SPDRP_HARDWAREID, out _, buf, buf.Length, out var size)) continue;
                var ids = System.Text.Encoding.Unicode.GetString(buf, 0, Math.Max(0, size)).Split('\0', StringSplitOptions.RemoveEmptyEntries);
                if (ids.Any(id => id.Equals(HardwareId, StringComparison.OrdinalIgnoreCase)) &&
                    SetupDiCallClassInstaller(DIF_REMOVE, set, ref data))
                    removed++;
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return removed;
    }

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetINFClass(string infName, out Guid classGuid, [Out] char[] className, int size, IntPtr requiredSize);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr hwnd);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid classGuid, string? desc, IntPtr hwnd, int flags, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data, uint prop, byte[] buf, int size);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiCallClassInstaller(uint dif, IntPtr set, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevs(IntPtr classGuid, string? enumerator, IntPtr hwnd, uint flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInfo(IntPtr set, uint index, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data, uint prop, out uint regType, byte[] buf, int size, out int required);
    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hardwareId, string infPath, uint flags, out bool reboot);
}
