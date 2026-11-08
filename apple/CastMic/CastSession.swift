import Foundation
import Network
import Observation

@MainActor
@Observable
final class CastSession {
    enum Status: Equatable { case idle, connecting, connected, reconnecting, error(String) }

    var host: String = UserDefaults.standard.string(forKey: "host") ?? ""
    /// Windows に表示される 6 桁のコード (Keychain に保存)
    var pairingCode: String = Keychain.load("pairingCode") ?? "" {
        didSet {
            let digits = String(pairingCode.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != pairingCode { pairingCode = digits; return }
            Keychain.save("pairingCode", digits)
        }
    }
    var status: Status = .idle
    var connectedName: String?
    var micEnabled = true { didSet { audio?.micEnabled = micEnabled } }
    var speakerEnabled = true { didSet { audio?.speakerEnabled = speakerEnabled } }
    var micGain: Float = UserDefaults.standard.object(forKey: "micGain") as? Float ?? 1 {
        didSet { audio?.micGain = micGain; UserDefaults.standard.set(micGain, forKey: "micGain") }
    }
    /// 次回接続時から有効
    var voiceProcessing: Bool = UserDefaults.standard.object(forKey: "voiceProcessing") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceProcessing, forKey: "voiceProcessing") }
    }
    var autoReconnect: Bool = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }
    var micLevel: Float = 0
    var latencyMs: Int?

    private var target: (endpoint: NWEndpoint, label: String)?
    private var connection: Connection?
    private var audio: AudioIO?
    private var pingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    var isActive: Bool {
        switch status {
        case .connected, .connecting, .reconnecting: true
        default: false
        }
    }

    func connect() {
        guard pairingCode.count == 6 else {
            status = .error("6 桁のペアリングコードを入力してください")
            return
        }
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        UserDefaults.standard.set(h, forKey: "host")
        connect(to: .hostPort(host: NWEndpoint.Host(h), port: 48100), label: h)
    }

    func connect(to endpoint: NWEndpoint, label: String) {
        guard pairingCode.count == 6 else {
            status = .error("6 桁のペアリングコードを入力してください")
            return
        }
        disconnect()
        target = (endpoint, label)
        open()
    }

    func disconnect() {
        target = nil
        retryTask?.cancel(); retryTask = nil
        teardown()
        status = .idle
    }

    private func open() {
        guard let target else { return }
        let c = Connection(endpoint: target.endpoint)
        let a = AudioIO(voiceProcessing: voiceProcessing)
        a.micEnabled = micEnabled
        a.speakerEnabled = speakerEnabled
        a.micGain = micGain
        a.onMic = { [weak c, weak self] data in
            c?.send(.micAudio, data)
            let lvl = Self.rms(data)
            Task { @MainActor in self?.micLevel = lvl }
        }
        c.onFrame = { [weak a, weak self] type, payload in
            switch type {
            case .speakerAudio: a?.playSpeaker(payload)
            case .ping: // Windows からのエコー
                let rtt = Self.rtt(payload)
                Task { @MainActor in self?.latencyMs = rtt }
            case .authFailed:
                Task { @MainActor in self?.authFailed() }
            case .hello:
                let name = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["name"] as? String
                Task { @MainActor in self?.connectedName = name }
            default: break
            }
        }
        c.onState = { [weak self] conn, st in
            Task { @MainActor in
                // 置き換え済みの古い接続からの通知は無視
                guard let self, self.connection === conn else { return }
                self.handle(st)
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
        micLevel = 0
        latencyMs = nil
        connectedName = nil
    }

    private func handle(_ st: Connection.State) {
        switch st {
        case .connecting: break
        case .ready:
            let hello = try? JSONSerialization.data(withJSONObject: ["name": Self.deviceName, "version": 1, "code": pairingCode])
            connection?.send(.hello, hello ?? Data())
            do {
                try audio?.start()
                status = .connected
                startPing()
            } catch {
                target = nil
                teardown()
                status = .error("オーディオ開始失敗: \(error.localizedDescription)")
            }
        case .failed(let m):
            lost(m)
        case .closed:
            if status == .connected { lost("切断されました") }
        }
    }

    /// コード違いは再試行しても無駄なので自動再接続しない
    private func authFailed() {
        target = nil
        retryTask?.cancel(); retryTask = nil
        teardown()
        status = .error("ペアリングコードが違います。Windows の CastMic に表示されているコードを入力してください。")
    }

    /// 接続が切れた: 自動再接続が有効なら 2 秒後に再試行
    private func lost(_ message: String) {
        teardown()
        guard target != nil, autoReconnect else {
            target = nil
            status = .error(message)
            return
        }
        status = .reconnecting
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.open()
        }
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
