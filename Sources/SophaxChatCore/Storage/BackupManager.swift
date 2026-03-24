// BackupManager.swift
// SophaxChatCore
//
// Encrypted local backup — no cloud, no server, no third party.
//
// Philosophy: You own your data. The backup file is encrypted with a key derived
// from a passphrase only you know. Nobody else — not us, not Apple — can open it.
//
// What is backed up:
//   • All messages (text, reactions, status, timestamps)
//   • Contacts (known peers: username, public keys, onion address)
//   • Your username
//
// What is intentionally NOT backed up:
//   • Identity private keys (they are device-bound by design)
//   • Session states (ephemeral — forward secrecy means they SHOULD not survive)
//   • Prekeys (regenerated automatically on new device)
//
// When restoring on a new device:
//   • A fresh identity is generated
//   • Message history is restored
//   • Contacts are restored (but sessions must be re-established — each peer will
//     see a new safety number, consistent with key continuity principles)
//
// Encryption:
//   • Key derivation: HKDF-SHA256(IKM: passphrase, salt: random 32B, info: "sophax-backup-v1")
//   • Cipher: AES-256-GCM
//   • File format: 4B magic | 1B version | 32B salt | 12B nonce | ciphertext+tag

import Foundation
import CryptoKit

public struct SophaxBackup: Codable {
    public let version:    Int            // = 1
    public let createdAt:  Date
    public let username:   String
    public let peers:      [KnownPeer]
    public let messages:   [String: [StoredMessage]]  // peerID → [StoredMessage]
}

public enum BackupError: Error, LocalizedError {
    case wrongPassphrase
    case corruptFile
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase:   return "Wrong passphrase — backup could not be decrypted."
        case .corruptFile:       return "Backup file is corrupt or was not created by SophaxChat."
        case .exportFailed(let r): return "Export failed: \(r)"
        }
    }
}

public final class BackupManager: Sendable {

    private static let magic:   [UInt8] = [0x53, 0x58, 0x42, 0x4B]  // "SXBK"
    private static let version: UInt8   = 1

    // MARK: - Export

    /// Build an encrypted backup blob from the given data.
    /// Returns raw Data — caller decides where to save it (file, share sheet, etc.).
    public static func export(
        backup: SophaxBackup,
        passphrase: String
    ) throws -> Data {
        let json     = try JSONEncoder().encode(backup)
        let salt     = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let key      = deriveKey(passphrase: passphrase, salt: salt)
        let sealed   = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else {
            throw BackupError.exportFailed("AES-GCM combined output unavailable")
        }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(version)
        out.append(salt)
        out.append(combined)   // 12B nonce + ciphertext + 16B tag
        return out
    }

    // MARK: - Import

    /// Decrypt and decode a backup blob.
    public static func `import`(
        data: Data,
        passphrase: String
    ) throws -> SophaxBackup {
        // Validate magic + version
        guard data.count > 4 + 1 + 32 + 12 + 16 else { throw BackupError.corruptFile }
        let fileMagic = [UInt8](data[0..<4])
        guard fileMagic == magic else { throw BackupError.corruptFile }
        // version byte at index 4 — reserved for future migration
        let salt     = data[5..<37]
        let combined = data[37...]

        let key = deriveKey(passphrase: passphrase, salt: Data(salt))
        do {
            let box      = try AES.GCM.SealedBox(combined: Data(combined))
            let json     = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(SophaxBackup.self, from: json)
        } catch {
            throw BackupError.wrongPassphrase
        }
    }

    // MARK: - Suggested filename

    public static func suggestedFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "sophaxchat-backup-\(fmt.string(from: Date())).sophaxbackup"
    }

    // MARK: - Private: Key derivation

    /// HKDF-SHA256: passphrase as IKM, random salt, fixed info tag.
    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let ikm  = SymmetricKey(data: Data(passphrase.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("sophax-backup-v1".utf8),
            outputByteCount: 32
        )
    }
}
