// AttachmentStore.swift
// SophaxChatCore
//
// Encrypted at-rest storage for binary attachments (images, audio).
//
// Architecture: same as MessageStore — AES-256-GCM with the shared Keychain master key.
// Files stored in Application Support/sophax_attachments/, excluded from iCloud backup.
// Each attachment is a separate file named by its UUID.

import Foundation
import CryptoKit

// Threading contract: all public methods must be called from a single thread or
// under external mutual exclusion. ChatManager owns the sole instance and accesses
// it on the main thread (or within a locked section).
public final class AttachmentStore: @unchecked Sendable {

    private let storageKey: SymmetricKey
    private let baseURL:    URL

    // MARK: - Init

    public init(keychain: KeychainManager) throws {
        // Share the master storage key with MessageStore
        if let existing = try? keychain.loadStorageKey() {
            self.storageKey = existing
        } else {
            let newKey = SymmetricKey(size: .bits256)
            try keychain.saveStorageKey(newKey)
            self.storageKey = newKey
        }

        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SophaxError.invalidMessageFormat("Application Support directory unavailable")
        }
        self.baseURL = appSupport.appendingPathComponent("sophax_attachments", isDirectory: true)

        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = baseURL
        try? mutableURL.setResourceValues(resourceValues)

        // .complete = file inaccessible while device is locked (strongest protection level).
        // Defence-in-depth on top of AES-256-GCM application-level encryption.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: baseURL.path
        )
    }

    // MARK: - Public API

    /// Encrypt and save attachment data under a stable UUID.
    public func save(_ data: Data, id: String) throws {
        let sealed = try AES.GCM.seal(data, using: storageKey)
        guard let combined = sealed.combined else {
            throw SophaxError.encryptionFailed("AES-GCM combined output unavailable")
        }
        let url = fileURL(for: id)
        try combined.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    /// Decrypt and return attachment data for the given ID.
    public func load(id: String) throws -> Data {
        let encryptedData = try Data(contentsOf: fileURL(for: id))
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            return try AES.GCM.open(sealedBox, using: storageKey)
        } catch {
            throw SophaxError.decryptionFailed
        }
    }

    /// Delete a single attachment file.
    public func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Delete every attachment file in the store. Used for full account wipe.
    public func wipeAll() throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func exists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    // MARK: - Private

    private func fileURL(for id: String) -> URL {
        let safeID = id.filter { $0.isHexDigit || $0 == "-" }
        return baseURL.appendingPathComponent(safeID)
    }
}
