// NFCContactManager.swift
// SophaxChat
//
// Tap two phones together to exchange contact cards — no QR, no internet, no server.
// Uses CoreNFC NDEF to write/read sophaxchat://add URLs.
//
// Not available on macOS Catalyst (no NFC hardware).

#if !targetEnvironment(macCatalyst) && canImport(CoreNFC)
import CoreNFC
import Combine

@MainActor
final class NFCContactManager: NSObject, ObservableObject {

    @Published var isScanning = false
    @Published var errorMessage: String?

    private var readerSession: NFCNDEFReaderSession?
    private var mode: Mode = .read
    private var writeURL: String = ""
    private var onRead: ((URL) -> Void)?

    private enum Mode { case read, write }

    // MARK: - Public API

    /// Start NFC scan to read another user's contact card.
    func readContact(onRead: @escaping (URL) -> Void) {
        guard NFCNDEFReaderSession.readingAvailable else {
            errorMessage = "NFC not available on this device."
            return
        }
        self.mode   = .read
        self.onRead = onRead
        let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        session.alertMessage = "Hold your phone near the other SophaxChat user's phone."
        self.readerSession = session
        isScanning = true
        session.begin()
    }

    /// Present this device's contact card via NFC so another device can scan it.
    func writeContact(url: String) {
        guard NFCNDEFReaderSession.readingAvailable else {
            errorMessage = "NFC not available on this device."
            return
        }
        self.mode     = .write
        self.writeURL = url
        let session   = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        session.alertMessage = "Hold your phone near the other SophaxChat user's phone."
        self.readerSession = session
        isScanning = true
        session.begin()
    }
}

// MARK: - NFCNDEFReaderSessionDelegate

extension NFCContactManager: NFCNDEFReaderSessionDelegate {

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let nsError = error as NSError
        // Code 200 = user cancelled — not a real error
        let message = nsError.code == 200 ? nil : error.localizedDescription
        Task { @MainActor in
            self.isScanning   = false
            self.readerSession = nil
            if let message { self.errorMessage = message }
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // Read mode: parse first URI record
        for message in messages {
            for record in message.records {
                guard record.typeNameFormat == .absoluteURI ||
                      (record.typeNameFormat == .nfcWellKnown && record.type == Data("U".utf8)) else { continue }

                // Extract URL from NDEF URI record
                guard var urlString = String(data: record.payload, encoding: .utf8) else { continue }
                // NDEF URI records prepend a 1-byte identifier — strip it for well-known type
                if record.typeNameFormat == .nfcWellKnown && !urlString.isEmpty {
                    urlString = String(urlString.dropFirst())
                }
                guard let url = URL(string: urlString),
                      url.scheme == "sophaxchat" else { continue }

                Task { @MainActor in
                    self.isScanning = false
                    self.onRead?(url)
                }
                return
            }
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        // Write mode: write our contact URL to the first detected tag
        guard let tag = tags.first else { return }
        session.connect(to: tag) { [weak self] error in
            guard let self, error == nil else {
                session.invalidate(errorMessage: "Connection failed.")
                return
            }
            tag.queryNDEFStatus { status, _, error in
                guard error == nil else {
                    session.invalidate(errorMessage: "Could not query tag.")
                    return
                }
                guard status == .readWrite else {
                    session.invalidate(errorMessage: "This NFC tag is read-only.")
                    return
                }
                // Build NDEF URI record
                guard let urlData = self.writeURL.data(using: .utf8) else {
                    session.invalidate(errorMessage: "Invalid contact URL.")
                    return
                }
                let payload = NFCNDEFPayload(
                    format: .absoluteURI,
                    type: Data(),
                    identifier: Data(),
                    payload: urlData
                )
                let ndefMessage = NFCNDEFMessage(records: [payload])
                tag.writeNDEF(ndefMessage) { error in
                    if let error {
                        session.invalidate(errorMessage: error.localizedDescription)
                    } else {
                        session.alertMessage = "Contact shared!"
                        session.invalidate()
                    }
                    Task { @MainActor in
                        self.isScanning = false
                    }
                }
            }
        }
    }
}

#endif
