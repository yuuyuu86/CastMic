import Foundation
import Network

/// Windows アプリへの TCP 接続
final class Connection: @unchecked Sendable {
    enum State: Equatable { case connecting, ready, failed(String), closed }

    // コールバックには自分自身を渡す: 古い接続からの遅れた通知を呼び出し側で無視できるように
    var onState: (@Sendable (Connection, State) -> Void)?
    var onFrame: (@Sendable (FrameType, Data) -> Void)?

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "castmic.net")
    private var rx = Data()

    convenience init(host: String, port: UInt16 = 48100) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
    }

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVoice
        conn = NWConnection(to: endpoint, using: params)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.onState?(self, .ready)
                self.receive()
            case .failed(let e): self.onState?(self, .failed(e.localizedDescription))
            case .waiting(let e): self.onState?(self, .failed(e.localizedDescription))
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
