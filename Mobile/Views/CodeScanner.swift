import QueenBeeLink
import SwiftUI
import VisionKit

/// The camera, looking for a Queen Bee pairing code. Any other QR code in view is ignored.
/// It reports a code every time it sees it, which is many times a second while the code is in view.
struct CodeScanner: UIViewControllerRepresentable {
    let found: (PairingCode) -> Void
    /// Called when the camera can't be used after all: another app has it, say, or the device is too hot.
    let unavailable: () -> Void

    /// False on a device that can't scan at all, such as the Simulator, which has no camera.
    static var isSupported: Bool { DataScannerViewController.isSupported }

    init(found: @escaping (PairingCode) -> Void, unavailable: @escaping () -> Void) {
        self.found = found
        self.unavailable = unavailable
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found, unavailable: unavailable) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.hasGivenUp else { return }
        do { try scanner.startScanning() } catch { context.coordinator.giveUp() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (PairingCode) -> Void
        private let unavailable: () -> Void
        /// Said once: a scanner that couldn't start is asked to again every time the screen is drawn.
        private(set) var hasGivenUp = false

        init(found: @escaping (PairingCode) -> Void, unavailable: @escaping () -> Void) {
            self.found = found
            self.unavailable = unavailable
        }

        func giveUp() {
            guard !hasGivenUp else { return }
            hasGivenUp = true
            // Not now: this can be called while the screen is being drawn, when nothing on it may be changed.
            Task { @MainActor in self.unavailable() }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            giveUp()
        }

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
