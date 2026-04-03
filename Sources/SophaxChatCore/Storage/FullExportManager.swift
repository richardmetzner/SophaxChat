// FullExportManager.swift
// SophaxChatCore
//
// Combined identity + message backup in a single encrypted file.
//
// File format (.sxfe — "SophaxChat Full Export"):
//   "SXFE" (4B) | 0x01 (version, 1B) | iterations (4B big-endian UInt32)
//   | salt (32B) | AES-256-GCM nonce+ciphertext+tag
//
// Plaintext payload:
//   JSON { signingKeyPrivate, dhKeyPrivate, username, backup: SophaxBackup }
//
// KDF: PBKDF2-HMAC-SHA256, 720 000 iterations.
// Minimum passphrase: 16 characters (same policy as identity export).
//
// Security notes:
//   • All sensitive intermediate buffers are zeroed with resetBytes before deallocation.
//   • Restoring overwrites both identity keys AND messages — use with care.
//   • DR session states are NOT included (forward secrecy — regenerated on next contact).

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Payload

private struct FullExportPayload: Codable {
    let signingKeyPrivate: Data     // Ed25519 raw 32B
    let dhKeyPrivate:      Data     // X25519 raw 32B
    let username:          String
    let exportedAt:        Date
    let backup:            SophaxBackup
}

// MARK: - Errors

public enum FullExportError: Error, LocalizedError {
    case wrongPassphrase
    case corruptFile
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase:      return "Wrong passphrase — export file could not be decrypted."
        case .corruptFile:          return "File is corrupt or was not created by SophaxChat."
        case .exportFailed(let r):  return "Export failed: \(r)"
        }
    }
}

// MARK: - Manager

public final class FullExportManager: Sendable {

    private static let magic:             [UInt8] = [0x53, 0x58, 0x46, 0x45]  // "SXFE"
    private static let fileVersion:       UInt8   = 1
    private static let pbkdf2Iterations           = 720_000
    private static let minPassphraseLength        = 16

    // MARK: - Export

    /// Encrypt and serialize identity keys + full message backup into a single blob.
    ///
    /// - Parameters:
    ///   - identity: The local `IdentityManager`.
    ///   - backup:   A `SophaxBackup` built from the current message store and peer list.
    ///   - passphrase: User-supplied passphrase (min 16 chars, enforced here).
    /// - Returns: Raw encrypted `Data` to be saved as a `.sxfe` file.
    public static func export(
        identity:   IdentityManager,
        backup:     SophaxBackup,
        passphrase: String
    ) throws -> Data {
        guard passphrase.count >= minPassphraseLength else {
            throw FullExportError.exportFailed("Passphrase must be at least \(minPassphraseLength) characters")
        }

        let sigKey = try identity.signingPrivateKeyData()
        let dhKey  = try identity.dhPrivateKeyData()

        let payload = FullExportPayload(
            signingKeyPrivate: sigKey,
            dhKeyPrivate:      dhKey,
            username:          identity.publicIdentity.username,
            exportedAt:        Date(),
            backup:            backup
        )

        let salt  = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let iters = pbkdf2Iterations

        var jsonData = try JSONEncoder().encode(payload)
        defer { jsonData.resetBytes(in: jsonData.startIndex..<jsonData.endIndex) }

        var derivedBuf = Data(repeating: 0, count: 32)
        defer { derivedBuf.resetBytes(in: derivedBuf.startIndex..<derivedBuf.endIndex) }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iters: iters, buf: &derivedBuf)

        let sealed = try AES.GCM.seal(jsonData, using: key)
        guard let combined = sealed.combined else {
            throw FullExportError.exportFailed("AES-GCM combined output unavailable")
        }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(fileVersion)
        withUnsafeBytes(of: UInt32(iters).bigEndian) { out.append(contentsOf: $0) }
        out.append(salt)
        out.append(combined)   // 12B nonce + ciphertext + 16B GCM tag
        return out
    }

    // MARK: - Restore

    /// Decrypt and restore a full export — writes identity keys to Keychain and
    /// replaces the current message store.
    ///
    /// - Parameters:
    ///   - data:         Raw blob previously produced by `export(identity:backup:passphrase:)`.
    ///   - passphrase:   The passphrase used during export.
    ///   - keychain:     The Keychain manager to write restored identity keys into.
    ///   - messageStore: The message store to restore conversation history into.
    /// - Returns: The restored username.
    /// - Throws: `FullExportError.wrongPassphrase` or `.corruptFile`.
    @discardableResult
    public static func restore(
        data:         Data,
        passphrase:   String,
        keychain:     KeychainManager,
        messageStore: MessageStore
    ) throws -> String {
        // magic(4) + version(1) + iters(4) + salt(32) + nonce(12) + tag(16) = 69 min
        let minSize = 4 + 1 + 4 + 32 + 12 + 16
        guard data.count > minSize else { throw FullExportError.corruptFile }

        let fileMagic = [UInt8](data[0..<4])
        guard fileMagic == magic else { throw FullExportError.corruptFile }
        guard data[4] == fileVersion else { throw FullExportError.corruptFile }

        let iters    = Int(UInt32(bigEndian: data[5..<9].withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard iters >= 100_000 else { throw FullExportError.corruptFile }

        let salt     = Data(data[9..<41])
        let combined = Data(data[41...])

        var derivedBuf = Data(repeating: 0, count: 32)
        defer { derivedBuf.resetBytes(in: derivedBuf.startIndex..<derivedBuf.endIndex) }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iters: iters, buf: &derivedBuf)

        var jsonData: Data
        do {
            let box  = try AES.GCM.SealedBox(combined: combined)
            jsonData = try AES.GCM.open(box, using: key)
        } catch {
            throw FullExportError.wrongPassphrase
        }
        defer { jsonData.resetBytes(in: jsonData.startIndex..<jsonData.endIndex) }

        let payload: FullExportPayload
        do {
            payload = try JSONDecoder().decode(FullExportPayload.self, from: jsonData)
        } catch {
            throw FullExportError.corruptFile
        }

        // Restore identity keys
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: payload.signingKeyPrivate)
        let dhKey      = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: payload.dhKeyPrivate)
        try keychain.saveSigningKey(signingKey)
        try keychain.saveDHIdentityKey(dhKey)
        try keychain.saveUsername(payload.username)

        // Restore messages and peers
        let backup = payload.backup
        for (peerID, msgs) in backup.messages {
            for msg in msgs {
                try? messageStore.append(message: msg)
            }
            _ = peerID  // peerID is the partition key embedded in each StoredMessage
        }

        return payload.username
    }

    // MARK: - Suggested filename

    public static func suggestedFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "sophaxchat-full-export-\(fmt.string(from: Date())).sxfe"
    }

    // MARK: - Private: Key derivation

    private static func deriveKey(
        passphrase: String,
        salt:       Data,
        iters:      Int,
        buf:        inout Data
    ) throws -> SymmetricKey {
        let passData = Data(passphrase.utf8)
        let status = buf.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                passData.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress, passData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iters),
                        derivedPtr.baseAddress, 32
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw FullExportError.exportFailed("PBKDF2 derivation failed (\(status))")
        }
        return SymmetricKey(data: buf)
    }
}
