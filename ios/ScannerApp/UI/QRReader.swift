import SwiftUI
import VisionKit

/// Apple's system scanner supplies QR detection, camera permission handling and focus. No token is
/// sent by detection: it only opens the offline SAS-confirmation screen.
struct QRReader: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }
    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            let fallback = UIViewController(); fallback.view.backgroundColor = .systemGray6; return fallback
        }
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { context.coordinator.failed = true }
        return scanner
    }
    func updateUIViewController(_ view: UIViewController, context: Context) { }
    static func dismantleUIViewController(_ view: UIViewController, coordinator: Coordinator) {
        (view as? DataScannerViewController)?.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var delivered = false
        var failed = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    delivered = true; dataScanner.stopScanning(); found(value); return
                }
            }
        }
    }
}
