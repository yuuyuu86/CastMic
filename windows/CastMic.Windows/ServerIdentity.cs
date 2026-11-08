using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace CastMic;

/// TLS 用の自己署名証明書。現在のユーザーの証明書ストア (CurrentUser\My) に
/// エクスポート不可の秘密鍵として保存し、次回以降も同じものを使う
/// (iPhone / Mac は初回接続時にこの証明書の指紋を記憶し、以後は変わったら接続を拒否する)。
public static class ServerIdentity
{
    const string Subject = "CN=CastMic Server";

    public static X509Certificate2 LoadOrCreate()
    {
        using (var store = new X509Store(StoreName.My, StoreLocation.CurrentUser))
        {
            store.Open(OpenFlags.ReadOnly);
            var existing = store.Certificates
                .Find(X509FindType.FindBySubjectDistinguishedName, Subject, false)
                .OfType<X509Certificate2>()
                .Where(c => c.HasPrivateKey && c.NotAfter > DateTime.Now.AddDays(30))
                .OrderByDescending(c => c.NotAfter)
                .FirstOrDefault();
            if (existing != null) return existing;
        }

        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var req = new CertificateRequest(Subject, key, HashAlgorithmName.SHA256);
        req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        req.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, false));
        using var temp = req.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(10));

        // 一時鍵のままだと SslStream で使えないので、永続化した上でストアに入れる
        var pfxPassword = Convert.ToBase64String(RandomNumberGenerator.GetBytes(24));
        var pfx = temp.Export(X509ContentType.Pfx, pfxPassword);
        var cert = new X509Certificate2(pfx, pfxPassword,
            X509KeyStorageFlags.UserKeySet | X509KeyStorageFlags.PersistKeySet);
        CryptographicOperations.ZeroMemory(pfx);
        using (var store = new X509Store(StoreName.My, StoreLocation.CurrentUser))
        {
            store.Open(OpenFlags.ReadWrite);
            store.Add(cert);
        }
        return cert;
    }

    /// SHA-256(DER) を 16 進で。iPhone / Mac 側の表示と同じ形式
    public static string Fingerprint(X509Certificate2 cert) =>
        Convert.ToHexString(SHA256.HashData(cert.RawData));

    /// 画面表示用: 先頭 16 文字を 4 文字区切り
    public static string ShortFingerprint(string fp) =>
        string.Join(" ", Enumerable.Range(0, 4).Select(i => fp.Substring(i * 4, 4)));
}
