import Foundation
import Network
import Observation

@MainActor
@Observable
final class CastSession {
    enum Status: Equatable { case idle, connecting, connected, reconnecting, error(String) }

    /// 接続候補 (QR の場合は PC 名 + 複数 IP を順に試す)
    struct Candidate {
        let endpoint: NWEndpoint
        /// 証明書の記憶に使うキー (PC 名 or IP)
        let label: String
    }

    /// Live Activity などアプリ外の UI から呼ぶため
    static private(set) var shared: CastSession?

    // MARK: 設定
    var host: String = UserDefaults.standard.string(forKey: "host") ?? ""
    /// Windows に表示される 6 桁のコード (Keychain に保存)
    var pairingCode: String = Keychain.load("pairingCode") ?? "" {
        didSet {
            let digits = String(pairingCode.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != pairingCode { pairingCode = digits; return }
            Keychain.save("pairingCode", digits)
        }
    }
    var micEnabled = CastSession.pref("micEnabled", true) {
        didSet { save("micEnabled", micEnabled); audio?.micEnabled = micEnabled; sendRoles() }
    }
    var speakerEnabled = CastSession.pref("speakerEnabled", true) {
        didSet { save("speakerEnabled", speakerEnabled); audio?.speakerEnabled = speakerEnabled; sendRoles() }
    }
    var micGain: Float = CastSession.pref("micGain", Float(1)) {
        didSet { save("micGain", micGain); audio?.micGain = micGain }
    }
    /// 次回接続時から有効
    var voiceProcessing = CastSession.pref("voiceProcessing", true) { didSet { save("voiceProcessing", voiceProcessing) } }
    var autoReconnect = CastSession.pref("autoReconnect", true) { didSet { save("autoReconnect", autoReconnect) } }
    /// 音声圧縮 (Opus)。次回接続時から有効
    var useOpus = CastSession.pref("useOpus", true) { didSet { save("useOpus", useOpus) } }
    /// 逆方向 (macOS のみ): Windows のマイク/スピーカーを Mac で使う。次回接続時から有効
    var reverseMode = CastSession.pref("reverseMode", false) { didSet { save("reverseMode", reverseMode) } }
    /// 遅延の上限 (ms)。小さいほど低遅延、大きいほど途切れにくい
    var bufferMs = CastSession.pref("bufferMs", 80) {
        didSet { save("bufferMs", bufferMs); audio?.bufferMs = bufferMs }
    }

    // MARK: 状態
    var status: Status = .idle
    var connectedName: String?
    var micLevel: Float = 0
    var latencyMs: Int?
    var codecName: String?
    /// Windows 側と共有のミュート状態
    private(set) var muted = false
    /// 接続中のサーバー証明書の確認コード (Windows に表示されるものと同じ)
    var fingerprint: String?
    /// 証明書が以前と違う接続先
    var mismatchLabel: String?
    /// 状態が変わったとき (Live Activity 更新用)
    var onChange: (() -> Void)?

    private var candidates: [Candidate] = []
    /// 今回の接続先に一度でもつながったか (初回接続の失敗は再試行せずエラーにする)
    private var everConnected = false
    private var candidateIndex = 0
    private var connection: Connection?
    private var audio: AudioIO?
    private var encoder: OpusEncoder?
    private var decoder: OpusDecoder?
    private var pingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init() { Self.shared = self }

    var isActive: Bool {
        switch status {
        case .connected, .connecting, .reconnecting: true
        default: false
        }
    }

    private var pins: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "pins") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "pins") }
    }

    // MARK: 接続

    func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        UserDefaults.standard.set(h, forKey: "host")
        connect([Candidate(endpoint: .hostPort(host: NWEndpoint.Host(h), port: 48100), label: h)])
    }

    func connect(to endpoint: NWEndpoint, label: String) {
        connect([Candidate(endpoint: endpoint, label: label)])
    }

    func connect(_ list: [Candidate]) {
        guard pairingCode.count == 6 else {
            status = .error("6 桁のペアリングコードを入力してください")
            return
        }
        disconnect()
        candidates = list
        candidateIndex = 0
        everConnected = false
        open()
    }

    /// castmic://pair?n=PC名&a=IP1,IP2&p=48100&c=123456&f=指紋
    /// QR から来た場合は証明書の指紋が分かっているので、最初から固定して接続する (なりすましできない)
    @discardableResult
    func handlePairURL(_ url: URL) -> Bool {
        guard url.scheme == "castmic", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func q(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let code = q("c"), code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }),
              let fp = q("f")?.uppercased(), fp.count == 64, fp.allSatisfy(\.isHexDigit) else {
            status = .error("QR コードを読み取れませんでした")
            return false
        }
        let port = NWEndpoint.Port(q("p") ?? "") ?? 48100
        let name = q("n").map { String($0.prefix(64)) }
        let addrs = (q("a") ?? "").split(separator: ",").map(String.init).filter { IPv4Address($0) != nil }.prefix(8)

        var list: [Candidate] = []
        if let name, !name.isEmpty {
            list.append(Candidate(endpoint: .service(name: name, type: "_castmic._tcp", domain: "local.", interface: nil), label: name))
        }
        list += addrs.map { Candidate(endpoint: .hostPort(host: NWEndpoint.Host($0), port: port), label: $0) }
        guard !list.isEmpty else { status = .error("QR コードに接続先がありません"); return false }

        var p = pins
        for c in list { p[c.label] = fp }
        pins = p
        pairingCode = code
        mismatchLabel = nil
        connect(list)
        return true
    }

    func disconnect() {
        candidates = []
        retryTask?.cancel(); retryTask = nil
        teardown()
        status = .idle
        onChange?()
    }

    /// 証明書が変わった PC を信頼し直す (PC を入れ替えた・再インストールした場合)
    func resetTrust() {
        guard let label = mismatchLabel else { return }
        pins[label] = nil
        mismatchLabel = nil
        status = .idle
    }

    func toggleMute() { setMuted(!muted) }

    func setMuted(_ m: Bool) {
        muted = m
        connection?.send(.muteState, Data([m ? 1 : 0]))
        onChange?()
    }

    // MARK: 内部

    private func open() {
        guard candidateIndex < candidates.count else { return }
        let target = candidates[candidateIndex]
        let c = Connection(endpoint: target.endpoint, pinnedFingerprint: pins[target.label])
        #if os(macOS)
        let reverse = reverseMode
        #else
        let reverse = false
        #endif
        let a = AudioIO(voiceProcessing: voiceProcessing, reverse: reverse)
        a.micEnabled = micEnabled
        a.speakerEnabled = speakerEnabled
        a.micGain = micGain
        a.bufferMs = bufferMs
        let enc = useOpus ? OpusEncoder(channels: UInt32(a.upChannels), bitrate: reverse ? 96_000 : 48_000) : nil
        let dec = useOpus ? OpusDecoder(channels: 2) : nil
        encoder = enc
        decoder = dec
        let wantOpus = enc != nil && dec != nil

        a.onMic = { [weak c, weak self] data in
            let lvl = Self.rms(data)
            Task { @MainActor in
                guard let self else { return }
                self.micLevel = lvl
                guard !self.muted, self.status == .connected else { return }
                if self.codecName == "Opus", let enc = self.encoder {
                    for p in enc.encode(data) { c?.send(.micOpus, p) }
                } else {
                    c?.send(.micAudio, data)
                }
            }
        }
        c.onFrame = { [weak a, weak self, dec] type, payload in
            switch type {
            case .speakerAudio: a?.playSpeaker(payload)
            case .speakerOpus:
                if let pcm = dec?.decode(payload) { a?.playSpeaker(pcm) }
            case .ping:
                let rtt = Self.rtt(payload)
                Task { @MainActor in self?.latencyMs = rtt }
            case .authFailed:
                Task { @MainActor in self?.authFailed() }
            case .muteState:
                let m = payload.first == 1
                Task { @MainActor in self?.muted = m; self?.onChange?() }
            case .hello:
                let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
                Task { @MainActor in self?.authSucceeded(obj ?? [:]) }
            default: break
            }
        }
        c.onState = { [weak self] conn, st in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.handle(st, wantOpus: wantOpus)
            }
        }
        a.onError = { [weak self] m in
            Task { @MainActor in self?.lost(m) }
        }
        connection = c
        audio = a
        if status != .reconnecting { status = .connecting }
        c.start()
    }

    private func teardown() {
        pingTask?.cancel(); pingTask = nil
        audio?.stop(); audio = nil
        connection?.cancel(); connection = nil
        encoder = nil; decoder = nil
        micLevel = 0
        latencyMs = nil
        connectedName = nil
        fingerprint = nil
        codecName = nil
    }

    private func handle(_ st: Connection.State, wantOpus: Bool) {
        switch st {
        case .connecting: break
        case .ready:
            let hello: [String: Any] = [
                "name": Self.deviceName, "version": 2, "code": pairingCode,
                "codec": wantOpus ? "opus" : "pcm",
                "mic": micEnabled, "speaker": speakerEnabled, "bufferMs": bufferMs,
                "mode": audio?.reverse == true ? "reverse" : "normal",
                "upChannels": Int(audio?.upChannels ?? 1),
            ]
            connection?.send(.hello, (try? JSONSerialization.data(withJSONObject: hello)) ?? Data())
            do {
                try audio?.start()
                status = .connected
                everConnected = true
                startPing()
                onChange?()
            } catch {
                candidates = []
                teardown()
                status = .error("オーディオ開始失敗: \(error.localizedDescription)")
            }
        case .failed(let m):
            // まだつながっていない候補なら次を試す
            if status != .connected, candidateIndex + 1 < candidates.count {
                teardown()
                candidateIndex += 1
                open()
            } else {
                lost(m)
            }
        case .certMismatch:
            mismatchLabel = candidates.indices.contains(candidateIndex) ? candidates[candidateIndex].label : nil
            candidates = []
            retryTask?.cancel(); retryTask = nil
            teardown()
            status = .error("PC の証明書が以前と違います。なりすましの可能性があります。PC を再インストールした等で心当たりがある場合のみ「信頼をリセット」してください。")
            onChange?()
        case .closed:
            if status == .connected { lost("切断されました") }
        }
    }

    private func authSucceeded(_ obj: [String: Any]) {
        connectedName = obj["name"] as? String
        codecName = (obj["codec"] as? String) == "opus" ? "Opus" : "PCM"
        muted = obj["muted"] as? Bool ?? false
        if let fp = connection?.peerFingerprint, candidates.indices.contains(candidateIndex) {
            fingerprint = Connection.shortFingerprint(fp)
            let label = candidates[candidateIndex].label
            if pins[label] == nil { pins[label] = fp }
        }
        onChange?()
    }

    /// コード違いは再試行しても無駄なので自動再接続しない
    private func authFailed() {
        candidates = []
        retryTask?.cancel(); retryTask = nil
        teardown()
        status = .error("ペアリングコードが違います。Windows の CastMic に表示されているコードを入力してください。")
        onChange?()
    }

    /// 接続が切れた: 自動再接続が有効なら 2 秒後に最初の候補から再試行
    private func lost(_ message: String) {
        teardown()
        guard !candidates.isEmpty, autoReconnect, everConnected else {
            let first = !everConnected
            candidates = []
            status = .error(first
                ? "PC に接続できませんでした。Windows で CastMic が起動しているか、同じネットワークにいるか確認してください。"
                : message)
            onChange?()
            return
        }
        status = .reconnecting
        onChange?()
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.candidateIndex = 0
            self.open()
        }
    }

    private func sendRoles() {
        guard status == .connected else { return }
        let roles = try? JSONSerialization.data(withJSONObject: ["mic": micEnabled, "speaker": speakerEnabled])
        connection?.send(.roles, roles ?? Data())
    }

    private func startPing() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                var now = UInt64(Date().timeIntervalSince1970 * 1000).littleEndian
                self?.connection?.send(.ping, Data(bytes: &now, count: 8))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: ヘルパー

    private static func pref<T>(_ key: String, _ def: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? def
    }
    private func save(_ key: String, _ v: Any) { UserDefaults.standard.set(v, forKey: key) }

    nonisolated static func rtt(_ d: Data) -> Int? {
        guard d.count == 8 else { return nil }
        let sent = d.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        return now >= sent ? Int(now - sent) : nil
    }

    static var deviceName: String {
        #if os(iOS)
        return ProcessInfo.processInfo.hostName
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    nonisolated static func rms(_ d: Data) -> Float {
        d.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            guard !s.isEmpty else { return 0 }
            var sum: Float = 0
            for v in s { let f = Float(v) / 32768; sum += f * f }
            return min(1, sqrt(sum / Float(s.count)) * 4)
        }
    }
}
