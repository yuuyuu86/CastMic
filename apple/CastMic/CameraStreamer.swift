import AVFoundation
import CoreImage

/// カメラ映像を 1280x720 / 最大 30fps の JPEG にして渡す (Windows の仮想カメラ「CastMic Camera」用)
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: ((Data) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "castmic.camera")
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var lastFrame: CFTimeInterval = 0
    private let front: Bool

    init(front: Bool) {
        self.front = front
    }

    enum CameraError: LocalizedError {
        case noCamera, denied
        var errorDescription: String? {
            switch self {
            case .noCamera: "カメラが見つかりません"
            case .denied: "カメラの使用が許可されていません。設定で CastMic のカメラを許可してください。"
            }
        }
    }

    func start() async throws {
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.denied }
        }
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
            ?? AVCaptureDevice.default(for: .video)
        #else
        let device = AVCaptureDevice.default(for: .video)
        #endif
        guard let device else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        #if os(iOS)
        // Web カメラは横長: iPhone を横向きに持ったときに正しい向きになる
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 }
        #endif
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrame >= 1.0 / 30 - 0.002, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        let image = CIImage(cvPixelBuffer: pb)
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6]
        if let jpeg = ci.jpegRepresentation(of: image, colorSpace: colorSpace, options: opts) {
            onFrame?(jpeg)
        }
    }
}
