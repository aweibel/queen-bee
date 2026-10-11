import QueenBeeLink
import SwiftUI
import VisionKit

/// The camera, looking for a Queen Bee pairing code. Any other QR code in view is ignored.
/// It reports a code every time it sees it, which is many times a second while the code is in view.
struct CodeScanner: UIViewControllerRepresentable {
    let found: (PairingCode) -> Void

    /// False on a device that can't scan at all, such as the Simulator, which has no camera.
    static var isSupported: Bool { DataScannerViewController.isSupported }

    init(found: @escaping (PairingCode) -> Void) { self.found = found }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (PairingCode) -> Void

        init(found: @escaping (PairingCode) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            look(at: addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            look(at: updatedItems)
        }

        private func look(at items: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                guard let text = barcode.payloadStringValue, let code = PairingCode(text: text) else { continue }
                found(code)
                return
            }
        }
    }
}
