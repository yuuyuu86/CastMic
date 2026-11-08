import AVFoundation

/// マイク取り込み (48kHz mono s16) とスピーカー再生 (48kHz stereo s16)
final class AudioIO: @unchecked Sendable {
    var onMic: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Frame.sampleRate, channels: 1, interleaved: true)!
    private let wireSpeakerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Frame.sampleRate, channels: 2, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: Frame.sampleRate, channels: 2)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var queuedFrames: AVAudioFrameCount = 0
    /// 再生キューの上限 (≒ 遅延上限) 120ms
    private let maxQueued: AVAudioFrameCount = 5760

    var micEnabled = true
    var speakerEnabled = true
    /// マイク音量 (倍率)
    var micGain: Float = 1
    /// エコーキャンセル + ノイズ抑制
    let voiceProcessing: Bool

    init(voiceProcessing: Bool) {
        self.voiceProcessing = voiceProcessing
    }

    func start() throws {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: voiceProcessing ? .voiceChat : .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try s.setPreferredSampleRate(Frame.sampleRate)
        try s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
        #endif

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(voiceProcessing)
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: micFormat)
        input.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [weak self] buf, _ in
            self?.handleMic(buf)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.withLock { queuedFrames = 0 }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
        if micGain != 1 {
            for i in 0..<Int(out.frameLength) {
                p[0][i] = Int16(max(-32768, min(32767, Float(p[0][i]) * micGain)))
            }
        }
        onMic?(Data(bytes: p[0], count: Int(out.frameLength) * 2))
    }

    /// Windows から届いたスピーカー音声を再生キューへ
    func playSpeaker(_ data: Data) {
        guard speakerEnabled else { return }
        let frames = AVAudioFrameCount(data.count / 4)
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
