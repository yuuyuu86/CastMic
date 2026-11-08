import Foundation

/// docs/PROTOCOL.md 参照
enum FrameType: UInt8 {
    case hello = 1
    case micAudio = 2
    case speakerAudio = 3
    case ping = 4
    case authFailed = 5
}

enum Frame {
    static let headerSize = 8
    static let sampleRate: Double = 48_000

    static func encode(_ type: FrameType, _ payload: Data) -> Data {
        var d = Data(capacity: headerSize + payload.count)
        d.append(contentsOf: [0x43, 0x4D, type.rawValue, 0])
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    /// バッファ先頭から完成したフレームを取り出す
    static func decode(_ buffer: inout Data) throws -> [(FrameType?, Data)] {
        var out: [(FrameType?, Data)] = []
        while buffer.count >= headerSize {
            let b = buffer.startIndex
            guard buffer[b] == 0x43, buffer[b + 1] == 0x4D else { throw CastError.badMagic }
            let type = FrameType(rawValue: buffer[b + 2])
            let len = Int(buffer[b + 4]) | Int(buffer[b + 5]) << 8 | Int(buffer[b + 6]) << 16 | Int(buffer[b + 7]) << 24
            guard len <= 64 * 1024 else { throw CastError.frameTooLarge }
            guard buffer.count >= headerSize + len else { break }
            out.append((type, Data(buffer[(b + headerSize)..<(b + headerSize + len)])))
            buffer.removeFirst(headerSize + len)
        }
        return out
    }
}

enum CastError: LocalizedError {
    case badMagic, frameTooLarge
    var errorDescription: String? {
        switch self {
        case .badMagic: "不正なデータを受信しました"
        case .frameTooLarge: "フレームが大きすぎます"
        }
    }
}
