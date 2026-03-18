// ContactScannerView.swift
// SophaxChat
//
// Camera QR scanner for adding contacts from a Contact Card.
// Uses VisionKit DataScannerViewController (iOS 16+).

import SwiftUI
import VisionKit
import SophaxChatCore

struct ContactScannerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var scannedResult: String? = nil
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    DataScannerRepresentable(scannedResult: $scannedResult)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text("Point at a SophaxChat QR code")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.black.opacity(0.5))
                                .clipShape(Capsule())
                                .padding(.bottom, 40)
                        }
                } else {
                    ContentUnavailableView(
                        "Scanner Unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text("Camera scanning is not available on this device.")
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: scannedResult) { _, result in
                guard let str = result, let url = URL(string: str) else { return }
                appState.handleIncomingLink(url)
                dismiss()
            }
            .alert("Invalid QR Code", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            }
        }
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    @Binding var scannedResult: String?

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(scannedResult: $scannedResult) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        @Binding var scannedResult: String?
        init(scannedResult: Binding<String?>) { _scannedResult = scannedResult }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item {
                scannedResult = barcode.payloadStringValue
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            // Auto-scan first found QR without requiring tap
            guard scannedResult == nil else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    scannedResult = payload
                    return
                }
            }
        }
    }
}
