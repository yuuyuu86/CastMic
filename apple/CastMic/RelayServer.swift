#if os(macOS)
import Foundation
import Network
import Observation

/// この Mac を中継にする: iPhone と Windows が直接つながらないネットワーク (学校の Wi-Fi と有線 LAN など) 用。
///
/// - Windows は "CMRH <room>\n" を送って待機する (room = 証明書指紋の先頭 32 桁)
/// - iPhone / Mac は TLS で接続し、TLS の宛先名 (SNI) に "r<room>.castmic.invalid" を入れる
/// - 中継は ClientHello の SNI だけを読んで部屋を探し、Windows に 0x01 を送ってから両方を素通しする
/// 中身は TLS で暗号化されたままなので、中継から音声は見えない。
@MainActor
@Observable
final class RelayServer {
    static let port: UInt16 = 48101
    private static let maxRooms = 32
    private static let maxHostsPerRoom = 4
    private static let maxConnections = 128

    private(set) var running = false
    private(set) var error: String?
    /// 待機中の PC (部屋) の数と、中継中の接続数
    private(set) var waitingHosts = 0
    private(set) var activePairs = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "castmic.relay")
    private let core = RelayCore()

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [core] c in core.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready: self?.running = true; self?.error = nil
                    case .failed(let e): self?.running = false; self?.error = e.localizedDescription; self?.stop()
                    default: break
                    }
                }
            }
            core.onStats = { [weak self] hosts, pairs in
                Task { @MainActor in self?.waitingHosts = hosts; self?.activePairs = pairs }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        core.closeAll()
    }

    /// 表示用: この Mac の IPv4 アドレス
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (a.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (a.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

/// 中継の本体 (ネットワークキュー上で動く)
final class RelayCore: @unchecked Sendable {
    var onStats: ((Int, Int) -> Void)?
    private let lock = NSLock()
    private var waiting: [String: [NWConnection]] = [:]
    private var all = Set<ObjectIdentifier>()
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private var paired = Set<ObjectIdentifier>()
    /// 待機していた PC → つながった端末
    private var partner: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "castmic.relay.core")

    func accept(_ c: NWConnection) {
        let ok = lock.withLock { () -> Bool in
            guard conns.count < 128 else { return false }
            conns[ObjectIdentifier(c)] = c
            return true
        }
        guard ok else { c.cancel(); return }
        c.stateUpdateHandler = { [weak self] st in
            if case .cancelled = st { self?.forget(c) }
            if case .failed = st { c.cancel() }
        }
        c.start(queue: queue)
        // 最初の 10 秒以内に、待機の宣言か ClientHello が来なければ切る
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            let undecided = self.lock.withLock { self.conns[ObjectIdentifier(c)] != nil && !self.decided.contains(ObjectIdentifier(c)) }
            if undecided { c.cancel() }
        }
        readHead(c, buffer: Data())
    }

    private var decided = Set<ObjectIdentifier>()

    /// 先頭を読んで、待機する PC か接続しに来た端末かを判断する
    private func readHead(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if err != nil || (done && buf.isEmpty) { c.cancel(); return }

            if buf.starts(with: Array("CMRH ".utf8)) {
                guard let nl = buf.firstIndex(of: 0x0A) else {
                    if buf.count > 64 { c.cancel() } else { self.readHead(c, buffer: buf) }
                    return
                }
                let room = String(decoding: buf[buf.startIndex + 5 ..< nl], as: UTF8.self)
                guard Self.validRoom(room) else { c.cancel(); return }
                self.addHost(c, room: room)
                return
            }

            switch Self.parseSNI(buf) {
            case .needMore:
                if buf.count > 16 * 1024 + 5 { c.cancel() } else { self.readHead(c, buffer: buf) }
            case .invalid:
                c.cancel()
            case .found(let sni):
                guard let room = Self.room(fromSNI: sni), let host = self.takeHost(room: room) else { c.cancel(); return }
                self.pair(client: c, host: host, firstBytes: buf)
            }
        }
    }

    private func addHost(_ c: NWConnection, room: String) {
        let ok = lock.withLock { () -> Bool in
            decided.insert(ObjectIdentifier(c))
            if waiting[room] == nil && waiting.count >= 32 { return false }
            if waiting[room, default: []].count >= 4 { return false }
            waiting[room, default: []].append(c)
            return true
        }
        guard ok else { c.cancel(); return }
        report()
        // 待機中の PC の切断を検知するための受信。
        // 端末とつながった後は、この受信で届いたデータ (TLS の応答) をそのまま端末へ流す
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            guard let client = self.lock.withLock({ self.partner[ObjectIdentifier(c)] }) else {
                c.cancel()   // まだ待機中なのに何か来た / 切れた
                return
            }
            if let data, !data.isEmpty {
                client.send(content: data, completion: .contentProcessed { e in if e != nil { c.cancel(); client.cancel() } })
            }
            if done || err != nil { c.cancel(); client.cancel(); return }
            self.pump(from: c, to: client)
        }
    }

    private func takeHost(room: String) -> NWConnection? {
        let h = lock.withLock { () -> NWConnection? in
            guard var list = waiting[room], !list.isEmpty else { return nil }
            let h = list.removeFirst()
            waiting[room] = list.isEmpty ? nil : list
            return h
        }
        report()
        return h
    }

    private func pair(client: NWConnection, host: NWConnection, firstBytes: Data) {
        lock.withLock {
            decided.insert(ObjectIdentifier(client))
            paired.insert(ObjectIdentifier(client))
            paired.insert(ObjectIdentifier(host))
            partner[ObjectIdentifier(host)] = client
        }
        report()
        var start = Data([0x01])
        start.append(firstBytes)
        host.send(content: start, completion: .contentProcessed { _ in })
        pump(from: client, to: host)
        // PC → 端末 は addHost で張った受信が引き継ぐ
    }

    /// 片方向の素通し。どちらかが切れたら両方閉じる
    private func pump(from a: NWConnection, to b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { e in
                    if e != nil { a.cancel(); b.cancel() }
                })
            }
            if done || err != nil {
                a.cancel(); b.cancel()
                return
            }
            self?.pump(from: a, to: b)
        }
    }

    private func forget(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        lock.withLock {
            conns[id] = nil
            decided.remove(id)
            for (room, list) in waiting {
                let rest = list.filter { $0 !== c }
                waiting[room] = rest.isEmpty ? nil : rest
            }
            paired.remove(id)
            partner[id] = nil
        }
        report()
    }

    func closeAll() {
        let list = lock.withLock { Array(conns.values) }
        list.forEach { $0.cancel() }
    }

    private func report() {
        let (h, p) = lock.withLock { (waiting.values.reduce(0) { $0 + $1.count }, (paired.count + 1) / 2) }
        onStats?(h, p)
    }

    // MARK: - 解析

    static func validRoom(_ r: String) -> Bool {
        r.count == 32 && r.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    /// "r<32桁>.castmic.invalid" → 部屋
    static func room(fromSNI sni: String) -> String? {
        let s = sni.lowercased()
        guard s.hasPrefix("r"), s.hasSuffix(".castmic.invalid") else { return nil }
        let room = String(s.dropFirst().dropLast(".castmic.invalid".count))
        return validRoom(room) ? room : nil
    }

    enum SNIResult: Equatable { case needMore, invalid, found(String) }

    /// TLS ClientHello から SNI を取り出す (最初のレコードだけを見る)
    static func parseSNI(_ d: Data) -> SNIResult {
        let b = [UInt8](d)
        guard b.count >= 5 else { return .needMore }
        guard b[0] == 0x16, b[1] == 0x03 else { return .invalid }        // handshake レコード
        let recLen = Int(b[3]) << 8 | Int(b[4])
        guard recLen <= 16 * 1024 else { return .invalid }
        guard b.count >= 5 + recLen else { return .needMore }
        var i = 5
        func u8() -> Int? { guard i < 5 + recLen else { return nil }; defer { i += 1 }; return Int(b[i]) }
        func u16() -> Int? { guard let h = u8(), let l = u8() else { return nil }; return h << 8 | l }
        func skip(_ n: Int) -> Bool { i += n; return i <= 5 + recLen }
        guard u8() == 0x01, skip(3), skip(2 + 32) else { return .invalid } // ClientHello, 長さ, version, random
        guard let sid = u8(), skip(sid), let cs = u16(), skip(cs), let cm = u8(), skip(cm),
              let extLen = u16() else { return .invalid }
        let extEnd = min(i + extLen, 5 + recLen)
        while i + 4 <= extEnd {
            guard let type = u16(), let len = u16() else { return .invalid }
            if type == 0x0000 {
                guard u16() != nil, u8() == 0x00, let nameLen = u16(), i + nameLen <= extEnd else { return .invalid }
                return .found(String(decoding: b[i ..< i + nameLen], as: UTF8.self))
            }
            guard skip(len) else { return .invalid }
        }
        return .invalid
    }
}
#endif
