import Foundation
import Network
import CryptoKit
import Security

/// Windows アプリへの TLS 接続。
/// サーバーは自己署名証明書なので、証明書の SHA-256 指紋で検証する (初回は記憶、以後は一致必須)。
final class Connection: @unchecked Sendable {
    enum State: Equatable { case connecting, ready, failed(String), certMismatch, closed }

    // コールバックには自分自身を渡す: 古い接続からの遅れた通知を呼び出し側で無視できるように
    var onState: (@Sendable (Connection, State) -> Void)?
    var onFrame: (@Sendable (FrameType, Data) -> Void)?

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "castmic.net")
    private var rx = Data()
    private let lock = NSLock()
    private var _peerFingerprint: String?
    private var _mismatch = false
    /// TLS ハンドシェイクで見えたサーバー証明書の指紋 (大文字 16 進)
    var peerFingerprint: String? { lock.withLock { _peerFingerprint } }

    /// - Parameter pinnedFingerprint: 記憶済みの指紋。nil なら初回接続として任意の証明書を受け入れる
    init(endpoint: NWEndpoint, pinnedFingerprint: String?) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        let params = NWParameters(tls: tls, tcp: tcp)
        params.serviceClass = .interactiveVoice
        conn = NWConnection(to: endpoint, using: params)

        sec_protocol_options_set_verify_block(sec, { [weak self] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else {
                complete(false); return
            }
            let der = SecCertificateCopyData(leaf) as Data
            let fp = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
            let ok = pinnedFingerprint == nil || pinnedFingerprint == fp
            self?.lock.withLock {
                self?._peerFingerprint = fp
                self?._mismatch = !ok
            }
            complete(ok)
        }, queue)
    }

    static func shortFingerprint(_ fp: String) -> String {
        stride(from: 0, to: 16, by: 4).map { i in
            let a = fp.index(fp.startIndex, offsetBy: i)
            return String(fp[a..<fp.index(a, offsetBy: 4)])
        }.joined(separator: " ")
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.onState?(self, .ready)
                self.receive()
            case .failed(let e), .waiting(let e):
                if self.lock.withLock({ self._mismatch }) {
                    self.onState?(self, .certMismatch)
                    self.conn.cancel()
                } else {
                    self.onState?(self, .failed(e.localizedDescription))
                }
            case .cancelled: self.onState?(self, .closed)
            default: break
            }
        }
        onState?(self, .connecting)
        conn.start(queue: queue)
    }

    func send(_ type: FrameType, _ payload: Data) {
        conn.send(content: Frame.encode(type, payload), completion: .idempotent)
    }

    func cancel() { conn.cancel() }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.rx.append(data) }
            do {
                for (t, p) in try Frame.decode(&self.rx) {
                    if let t { self.onFrame?(t, p) }
                }
            } catch {
                self.onState?(self, .failed(error.localizedDescription)); self.conn.cancel(); return
            }
            if let err { self.onState?(self, .failed(err.localizedDescription)); return }
            if done { self.conn.cancel(); return }
            self.receive()
        }
    }
}
