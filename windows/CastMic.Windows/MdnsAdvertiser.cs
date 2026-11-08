using System.Runtime.InteropServices;

namespace CastMic;

/// Windows 10 1809+ の DnsServiceRegister で _castmic._tcp を mDNS 広告する
/// (iPhone / Mac アプリの「見つかった PC」に表示される)
public sealed class MdnsAdvertiser : IDisposable
{
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void RegisterComplete(uint status, IntPtr context, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    struct DNS_SERVICE_REGISTER_REQUEST
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr pServiceInstance;
        public IntPtr pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        public IntPtr hCredentials;
        public int unicastEnabled;
    }

    const uint DNS_QUERY_REQUEST_VERSION1 = 1;
    const uint DNS_REQUEST_PENDING = 9506;

    readonly RegisterComplete _callback; // GC されないよう保持
    IntPtr _instance;
    DNS_SERVICE_REGISTER_REQUEST _request;
    bool _registered;

    public MdnsAdvertiser() => _callback = (_, _, inst) => { if (inst != IntPtr.Zero) DnsServiceFreeInstance(inst); };

    public bool Start(ushort port)
    {
        var host = Environment.MachineName;
        _instance = DnsServiceConstructInstance($"{host}._castmic._tcp.local", $"{host}.local",
            IntPtr.Zero, IntPtr.Zero, port, 0, 0, 0, IntPtr.Zero, IntPtr.Zero);
        if (_instance == IntPtr.Zero) return false;

        _request = new DNS_SERVICE_REGISTER_REQUEST
        {
            Version = DNS_QUERY_REQUEST_VERSION1,
            pServiceInstance = _instance,
            pRegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(_callback),
        };
        _registered = DnsServiceRegister(ref _request, IntPtr.Zero) == DNS_REQUEST_PENDING;
        return _registered;
    }

    public void Dispose()
    {
        if (_registered) { DnsServiceDeRegister(ref _request, IntPtr.Zero); _registered = false; }
        if (_instance != IntPtr.Zero) { DnsServiceFreeInstance(_instance); _instance = IntPtr.Zero; }
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, IntPtr ip4, IntPtr ip6,
        ushort port, ushort priority, ushort weight, uint propertiesCount, IntPtr keys, IntPtr values);
    [DllImport("dnsapi.dll")]
    static extern uint DnsServiceRegister(ref DNS_SERVICE_REGISTER_REQUEST request, IntPtr cancel);
    [DllImport("dnsapi.dll")]
    static extern uint DnsServiceDeRegister(ref DNS_SERVICE_REGISTER_REQUEST request, IntPtr cancel);
    [DllImport("dnsapi.dll")]
    static extern void DnsServiceFreeInstance(IntPtr instance);
}
