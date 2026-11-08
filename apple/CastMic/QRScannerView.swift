#if os(iOS)
import SwiftUI
import VisionKit

/// Windows に表示された QR (castmic://pair?...) を読み取る
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    /// isAvailable はカメラ許可前だと false になるので、対応端末かどうか (isSupported) だけで判断する。
    /// 許可はボタンを押したときに求める
    static var isAvailable: Bool { DataScannerViewController.isSupported }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (URL) -> Void
        private var done = false
        init(onFound: @escaping (URL) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                if let s = code.payloadStringValue, let url = URL(string: s), url.scheme == "castmic" {
                    done = true
                    onFound(url)
                    return
                }
            }
        }
    }
}
#endif
