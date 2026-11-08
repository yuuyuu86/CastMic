import AVFoundation

/// CoreAudio の Opus エンコーダ/デコーダ (生の Opus パケット, 20ms = 960 フレーム)
enum Opus {
    static let frameSize: AVAudioFrameCount = 960

    static func format(channels: UInt32) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Frame.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSize), mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)
    }

    static func pcmFormat(channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Frame.sampleRate, channels: channels, interleaved: true)!
    }
}

/// s16le PCM を溜めて 20ms ごとに Opus パケットにする
final class OpusEncoder {
    private let pcm: AVAudioFormat
    private let opus: AVAudioFormat
    private let converter: AVAudioConverter
    private let bytesPerFrame: Int
    private var pending = Data()

    init?(channels: UInt32, bitrate: Int) {
        guard let opus = Opus.format(channels: channels) else { return nil }
        let pcm = Opus.pcmFormat(channels: AVAudioChannelCount(channels))
        guard let conv = AVAudioConverter(from: pcm, to: opus) else { return nil }
        conv.bitRate = bitrate
        self.pcm = pcm
        self.opus = opus
        converter = conv
        bytesPerFrame = Int(channels) * 2
    }

    func encode(_ data: Data) -> [Data] {
        pending.append(data)
        let chunk = Int(Opus.frameSize) * bytesPerFrame
        var packets: [Data] = []
        while pending.count >= chunk {
            guard let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: Opus.frameSize) else { break }
            input.frameLength = Opus.frameSize
            pending.prefix(chunk).withUnsafeBytes { src in
                input.int16ChannelData![0].update(from: src.bindMemory(to: Int16.self).baseAddress!, count: chunk / 2)
            }
            pending.removeFirst(chunk)

            let maxSize = max(converter.maximumOutputPacketSize, 1500)
            let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: maxSize)
            var fed = false
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return input
            }
            guard status != .error, out.packetCount > 0, let desc = out.packetDescriptions else { continue }
            let d = desc[0]
            packets.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
        }
        return packets
    }
}

/// Opus パケット → s16le PCM
final class OpusDecoder {
    private let pcm: AVAudioFormat
    private let opus: AVAudioFormat
    private let converter: AVAudioConverter

    init?(channels: UInt32) {
        guard let opus = Opus.format(channels: channels) else { return nil }
        let pcm = Opus.pcmFormat(channels: AVAudioChannelCount(channels))
        guard let conv = AVAudioConverter(from: opus, to: pcm) else { return nil }
        self.pcm = pcm
        self.opus = opus
        converter = conv
    }

    func decode(_ packet: Data) -> Data? {
        guard !packet.isEmpty, packet.count <= 1500 else { return nil }
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        input.packetCount = 1
        input.byteLength = UInt32(packet.count)

        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: Opus.frameSize * 6) else { return nil }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return input
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * Int(pcm.channelCount) * 2)
    }
}
