import Foundation
import Observation

@MainActor
@Observable
final class CastSession {
    enum Status: Equatable { case idle, connecting, connected, error(String) }

    var host: String = UserDefaults.standard.string(forKey: "host") ?? ""
    var status: Status = .idle
    var micEnabled = true { didSet { audio?.micEnabled = micEnabled } }
    var speakerEnabled = true { didSet { audio?.speakerEnabled = speakerEnabled } }
    var micLevel: Float = 0

    private var connection: Connection?
    private var audio: AudioIO?

    func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        UserDefaults.standard.set(h, forKey: "host")
        disconnect()

        let c = Connection(host: h)
        let a = AudioIO()
        a.micEnabled = micEnabled
        a.speakerEnabled = speakerEnabled
        a.onMic = { [weak c, weak self] data in
            c?.send(.micAudio, data)
            let lvl = Self.rms(data)
            Task { @MainActor in self?.micLevel = lvl }
        }
        c.onFrame = { [weak a, weak c] type, payload in
            switch type {
            case .speakerAudio: a?.playSpeaker(payload)
            case .ping: c?.send(.ping, payload)
            default: break
            }
        }
        c.onState = { [weak self] st in
            Task { @MainActor in self?.handle(st) }
        }
        connection = c
        audio = a
        c.start()
    }

    func disconnect() {
        audio?.stop(); audio = nil
        connection?.cancel(); connection = nil
        status = .idle
        micLevel = 0
    }

    private func handle(_ st: Connection.State) {
        switch st {
        case .connecting: status = .connecting
        case .ready:
            let name = ProcessInfo.processInfo.hostName
            let hello = try? JSONSerialization.data(withJSONObject: ["name": name, "version": 1])
            connection?.send(.hello, hello ?? Data())
            do {
                try audio?.start()
                status = .connected
            } catch {
                status = .error("オーディオ開始失敗: \(error.localizedDescription)")
                connection?.cancel()
            }
        case .failed(let m):
            audio?.stop(); audio = nil; connection = nil
            status = .error(m)
        case .closed:
            if status == .connected || status == .connecting { disconnect() }
        }
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
