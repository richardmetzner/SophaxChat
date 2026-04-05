// IdentityExport.swift
// SophaxChatCore
//
// Encrypted identity key backup — lets users transfer their Ed25519 + X25519
// keypair to a new device without losing their peerID.
//
// What is exported:
//   • Ed25519 signing private key (32 bytes)
//   • X25519 DH private key (32 bytes)
//   • Username
//
// What is intentionally NOT exported:
//   • DR session states (ephemeral, forward secrecy)
//   • Prekeys (regenerated on restore)
//   • Messages and contacts (use BackupManager for those)
//
// File format (version 2):
//   "SXID" (4B) | 0x02 (version, 1B) | iterations (4B big-endian UInt32) | salt (32B) | nonce+ciphertext+tag (AES-256-GCM)
//
// KDF: PBKDF2-HMAC-SHA256, 600 000 iterations stored in file (minimum 100 000 on import).
// Minimum passphrase: 16 characters (enforced here and in UI).
//
// Security note:
//   Importing an identity backup replaces current Keychain keys.
//   All existing DR sessions become invalid — peers will see a key change alert
//   and must re-verify Safety Numbers.

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Payload

private struct IdentityPayload: Codable {
    let signingKeyPrivate: Data   // Ed25519 raw 32B
    let dhKeyPrivate:      Data   // X25519 raw 32B
    let username:          String
    let exportedAt:        Date
}

// MARK: - Errors

public enum IdentityExportError: Error, LocalizedError {
    case wrongPassphrase
    case corruptFile
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase:      return "Wrong passphrase — identity file could not be decrypted."
        case .corruptFile:          return "Identity file is corrupt or was not created by SophaxChat."
        case .exportFailed(let r):  return "Export failed: \(r)"
        }
    }
}

// MARK: - Manager

public final class IdentityExportManager: Sendable {

    private static let magic:              [UInt8] = [0x53, 0x58, 0x49, 0x44]  // "SXID"
    private static let fileVersion:        UInt8   = 2
    private static let pbkdf2Iterations            = 600_000
    private static let minPassphraseLength         = 16

    // MARK: - Export

    /// Serialize and encrypt the local identity keys + username.
    /// - Parameters:
    ///   - identity: The local `IdentityManager` holding keypair and username.
    ///   - passphrase: User-supplied passphrase (min 16 chars, enforced here).
    /// - Returns: Raw encrypted blob suitable for file export / share sheet.
    public static func export(identity: IdentityManager, passphrase: String) throws -> Data {
        guard passphrase.count >= minPassphraseLength else {
            throw IdentityExportError.exportFailed("Passphrase must be at least \(minPassphraseLength) characters")
        }

        let sigKey = try identity.signingPrivateKeyData()
        let dhKey  = try identity.dhPrivateKeyData()
        let uname  = identity.publicIdentity.username

        let payload = IdentityPayload(
            signingKeyPrivate: sigKey,
            dhKeyPrivate:      dhKey,
            username:          uname,
            exportedAt:        Date()
        )

        let salt  = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let iters = pbkdf2Iterations

        var jsonData = try JSONEncoder().encode(payload)
        defer { jsonData.resetBytes(in: jsonData.startIndex..<jsonData.endIndex) }

        var derivedBytes = Data(repeating: 0, count: 32)
        defer { derivedBytes.resetBytes(in: derivedBytes.startIndex..<derivedBytes.endIndex) }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iters, derivedBytes: &derivedBytes)

        let sealed = try AES.GCM.seal(jsonData, using: key)
        guard let combined = sealed.combined else {
            throw IdentityExportError.exportFailed("AES-GCM combined output unavailable")
        }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(fileVersion)
        // Store iteration count (big-endian UInt32) so future imports can adapt without
        // breaking existing backups when the constant is increased.
        withUnsafeBytes(of: UInt32(iters).bigEndian) { out.append(contentsOf: $0) }
        out.append(salt)
        out.append(combined)   // 12B nonce + ciphertext + 16B GCM tag
        return out
    }

    // MARK: - Import

    /// Decrypt an identity backup and write the keys into the Keychain.
    /// - Parameters:
    ///   - data: Raw blob previously produced by `export(identity:passphrase:)`.
    ///   - passphrase: The passphrase used during export.
    ///   - keychain: The Keychain manager to write restored keys into.
    /// - Returns: The restored username.
    /// - Throws: `IdentityExportError.wrongPassphrase` or `.corruptFile`.
    @discardableResult
    public static func `import`(
        data:       Data,
        passphrase: String,
        keychain:   KeychainManager
    ) throws -> String {
        // magic(4) + version(1) + iterations(4) + salt(32) + nonce(12) + tag(16) = 69 min
        let minSize = 4 + 1 + 4 + 32 + 12 + 16
        guard data.count > minSize else { throw IdentityExportError.corruptFile }
        let fileMagic = [UInt8](data[0..<4])
        guard fileMagic == magic else { throw IdentityExportError.corruptFile }
        guard data[4] == fileVersion else { throw IdentityExportError.corruptFile }

        // Read PBKDF2 iteration count from bytes 5–8 (big-endian UInt32)
        let iterBytes  = data[5..<9]
        let iterations = iterBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // Reject iteration counts below the current export default — prevents a crafted
        // backup from forcing a weaker KDF than the app itself would produce.
        guard iterations >= 600_000 else { throw IdentityExportError.corruptFile }

        let salt     = data[9..<41]
        let combined = data[41...]

        return try autoreleasepool {
            var derivedBytes = Data(repeating: 0, count: 32)
            defer { derivedBytes.resetBytes(in: derivedBytes.startIndex..<derivedBytes.endIndex) }
            let key = try deriveKey(passphrase: passphrase, salt: Data(salt), iterations: Int(iterations), derivedBytes: &derivedBytes)

            var jsonData: Data
            do {
                let box = try AES.GCM.SealedBox(combined: Data(combined))
                jsonData = try AES.GCM.open(box, using: key)
            } catch {
                throw IdentityExportError.wrongPassphrase
            }
            defer { jsonData.resetBytes(in: jsonData.startIndex..<jsonData.endIndex) }

            let payload: IdentityPayload
            do {
                payload = try JSONDecoder().decode(IdentityPayload.self, from: jsonData)
            } catch {
                throw IdentityExportError.corruptFile
            }

            // Write private keys into Keychain (overwrites existing identity)
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: payload.signingKeyPrivate)
            let dhKey      = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: payload.dhKeyPrivate)
            try keychain.saveSigningKey(signingKey)
            try keychain.saveDHIdentityKey(dhKey)
            try keychain.saveUsername(payload.username)

            return payload.username
        }
    }

    // MARK: - Suggested filename

    public static func suggestedFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "sophaxchat-identity-\(fmt.string(from: Date())).sophaxid"
    }

    // MARK: - Private: Key derivation

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int, derivedBytes: inout Data) throws -> SymmetricKey {
        var passData = Data(passphrase.utf8)
        defer { passData.resetBytes(in: 0..<passData.count) }

        let status = derivedBytes.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                passData.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress, passData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr.baseAddress, 32
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw IdentityExportError.exportFailed("PBKDF2 derivation failed (\(status))")
        }
        return SymmetricKey(data: derivedBytes)
    }
}
