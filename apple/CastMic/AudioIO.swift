import AVFoundation

/// マイク取り込み (48kHz mono s16) とスピーカー再生 (48kHz stereo s16)
final class AudioIO: @unchecked Sendable {
    var onMic: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// 送信する音声のチャンネル数 (通常 = マイク 1ch / 逆方向 = Mac の出力音 2ch)
    let upChannels: AVAudioChannelCount
    private let micFormat: AVAudioFormat
    /// 逆方向モード (macOS のみ): 「CastMic Speaker」から録音し、「CastMic Microphone」へ再生する
    let reverse: Bool
    private var captureEngine: AVAudioEngine?
    private let wireSpeakerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Frame.sampleRate, channels: 2, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: Frame.sampleRate, channels: 2)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var queuedFrames: AVAudioFrameCount = 0
    /// 再生キューの上限 (≒ 遅延上限)
    private var maxQueued: AVAudioFrameCount = 3840
    /// 遅延上限 (ms)。小さいほど低遅延、大きいほど途切れにくい
    var bufferMs: Int = 80 {
        didSet { lock.withLock { maxQueued = AVAudioFrameCount(max(20, bufferMs) * 48) } }
    }

    var micEnabled = true
    var speakerEnabled = true
    /// マイク音量 (倍率)
    var micGain: Float = 1
    /// エコーキャンセル + ノイズ抑制
    let voiceProcessing: Bool

    private var running = false
    private var observers: [NSObjectProtocol] = []

    init(voiceProcessing: Bool, reverse: Bool = false) {
        self.reverse = reverse
        self.voiceProcessing = reverse ? false : voiceProcessing
        upChannels = reverse ? 2 : 1
        micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Frame.sampleRate, channels: upChannels, interleaved: true)!
    }

    enum AudioIOError: LocalizedError {
        case deviceNotFound(String)
        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let n): "「\(n)」が見つかりません。Mac 用 CastMic ドライバをインストールしてください。"
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() throws {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: voiceProcessing ? .voiceChat : .default, options: [.defaultToSpeaker, .bluetoothHFP, .mixWithOthers])
        try s.setPreferredSampleRate(Frame.sampleRate)
        try s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
        #endif

        var captureFrom = engine
        #if os(macOS)
        if reverse {
            guard let spk = Self.deviceID(uid: "CastMic.Speaker") else { throw AudioIOError.deviceNotFound("CastMic Speaker") }
            guard let mic = Self.deviceID(uid: "CastMic.Microphone") else { throw AudioIOError.deviceNotFound("CastMic Microphone") }
            let cap = AVAudioEngine()
            try cap.inputNode.auAudioUnit.setDeviceID(spk)
            try engine.outputNode.auAudioUnit.setDeviceID(mic)
            captureEngine = cap
            captureFrom = cap
        }
        #endif
        let input = captureFrom.inputNode
        if !reverse { try? input.setVoiceProcessingEnabled(voiceProcessing) }
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: micFormat)
        input.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [weak self] buf, _ in
            self?.handleMic(buf)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.prepare()
        try engine.start()
        if let cap = captureEngine {
            cap.prepare()
            try cap.start()
        }
        player.play()
        lock.withLock { running = true }
        observeRestarts()
    }

    /// デバイス変更 (イヤホン抜き差し・Mac の入力切替) や電話着信の後にエンジンを立て直す
    private func observeRestarts() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        })
        #if os(iOS)
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restart()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        })
        #endif
    }

    private func restart() {
        guard lock.withLock({ running }) else { return }
        stopEngine()
        do { try start() } catch { onError?("オーディオ再開失敗: \(error.localizedDescription)") }
    }

    var onError: ((String) -> Void)?

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        lock.withLock { running = false }
        stopEngine()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func stopEngine() {
        if let cap = captureEngine {
            cap.inputNode.removeTap(onBus: 0)
            cap.stop()
            captureEngine = nil
        } else {
            engine.inputNode.removeTap(onBus: 0)
        }
        player.stop()
        engine.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        lock.withLock { queuedFrames = 0; running = false }
    }

    private func handleMic(_ buf: AVAudioPCMBuffer) {
        guard micEnabled, let converter else { return }
        let ratio = Frame.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData else { return }
        let samples = Int(out.frameLength) * Int(upChannels)
        if micGain != 1 {
            for i in 0..<samples {
                p[0][i] = Int16(max(-32768, min(32767, Float(p[0][i]) * micGain)))
            }
        }
        onMic?(Data(bytes: p[0], count: samples * 2))
    }

    /// Windows から届いたスピーカー音声を再生キューへ
    func playSpeaker(_ data: Data) {
        guard speakerEnabled, lock.withLock({ running }) else { return }
        let frames = AVAudioFrameCount(data.count / 4)
        guard frames <= lock.withLock({ maxQueued }) else { return }
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frames) else { return }
        // 遅延が溜まりすぎたら捨てる
        let over = lock.withLock { queuedFrames + frames > maxQueued }
        if over { return }
        buf.frameLength = frames
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<Int(frames) {
                l[i] = Float(Int16(littleEndian: s[i * 2])) / 32768
                r[i] = Float(Int16(littleEndian: s[i * 2 + 1])) / 32768
            }
        }
        lock.withLock { queuedFrames += frames }
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.queuedFrames -= min(self.queuedFrames, frames) }
        }
    }
}

#if os(iOS)
extension AVAudioSession.CategoryOptions {
    /// 新 SDK では allowBluetoothHFP、旧 SDK では allowBluetooth (同じ値)。どちらの Xcode でもビルドできるよう生の値で指定
    static let bluetoothHFP = AVAudioSession.CategoryOptions(rawValue: 0x4)
}
#endif

#if os(macOS)
import CoreAudio

extension AudioIO {
    /// デバイス UID → AudioDeviceID
    static func deviceID(uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static var isDriverInstalled: Bool { deviceID(uid: "CastMic.Speaker") != nil }
}
#endif
