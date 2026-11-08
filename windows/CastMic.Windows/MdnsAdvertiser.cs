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

    // 登録解除の完了コールバックはオブジェクト破棄後に来ることがあるので static で保持
    static readonly RegisterComplete Callback = (_, _, inst) => { if (inst != IntPtr.Zero) DnsServiceFreeInstance(inst); };
    IntPtr _instance;
    // 非同期 API なのでリクエストはアンマネージドメモリに置き、移動・解放されないようにする
    IntPtr _request;
    bool _registered, _registeredOnce;

    public bool Start(ushort port)
    {
        var host = Environment.MachineName;
        _instance = DnsServiceConstructInstance($"{host}._castmic._tcp.local", $"{host}.local",
            IntPtr.Zero, IntPtr.Zero, port, 0, 0, 0, IntPtr.Zero, IntPtr.Zero);
        if (_instance == IntPtr.Zero) return false;

        _request = Marshal.AllocHGlobal(Marshal.SizeOf<DNS_SERVICE_REGISTER_REQUEST>());
        Marshal.StructureToPtr(new DNS_SERVICE_REGISTER_REQUEST
        {
            Version = DNS_QUERY_REQUEST_VERSION1,
            pServiceInstance = _instance,
            pRegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(Callback),
        }, _request, false);
        _registered = DnsServiceRegister(_request, IntPtr.Zero) == DNS_REQUEST_PENDING;
        _registeredOnce |= _registered;
        return _registered;
    }

    public void Dispose()
    {
        if (_registered) { DnsServiceDeRegister(_request, IntPtr.Zero); _registered = false; }
        // _request は登録解除が非同期に参照し得るので、プロセス終了まで解放しない (1 回だけの小さなリーク)
        if (_instance != IntPtr.Zero && !_registeredOnce) { DnsServiceFreeInstance(_instance); }
        _instance = IntPtr.Zero;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, IntPtr ip4, IntPtr ip6,
        ushort port, ushort priority, ushort weight, uint propertiesCount, IntPtr keys, IntPtr values);
    [DllImport("dnsapi.dll")]
    static extern uint DnsServiceRegister(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll")]
    static extern uint DnsServiceDeRegister(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll")]
    static extern void DnsServiceFreeInstance(IntPtr instance);
}
