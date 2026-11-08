import Foundation
import Network

/// Windows アプリへの TCP 接続
final class Connection: @unchecked Sendable {
    enum State: Equatable { case connecting, ready, failed(String), closed }

    var onState: (@Sendable (State) -> Void)?
    var onFrame: (@Sendable (FrameType, Data) -> Void)?

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "castmic.net")
    private var rx = Data()

    init(host: String, port: UInt16 = 48100) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVoice
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.onState?(.ready)
                self.receive()
            case .failed(let e): self.onState?(.failed(e.localizedDescription))
            case .waiting(let e): self.onState?(.failed(e.localizedDescription))
            case .cancelled: self.onState?(.closed)
            default: break
            }
        }
        onState?(.connecting)
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
                self.onState?(.failed(error.localizedDescription)); self.conn.cancel(); return
            }
            if let err { self.onState?(.failed(err.localizedDescription)); return }
            if done { self.conn.cancel(); return }
            self.receive()
        }
    }
}
