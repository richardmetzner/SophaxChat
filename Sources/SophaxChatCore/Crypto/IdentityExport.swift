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
// File format:
//   "SXID" (4B) | 0x01 (version, 1B) | salt (32B) | nonce+ciphertext+tag (AES-256-GCM)
//
// KDF: PBKDF2-HMAC-SHA256, 600 000 iterations (same as BackupManager).
// Minimum passphrase: 12 characters (enforced in UI).
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

    private static let magic:          [UInt8] = [0x53, 0x58, 0x49, 0x44]  // "SXID"
    private static let fileVersion:    UInt8   = 1
    private static let pbkdf2Iterations        = 600_000

    // MARK: - Export

    /// Serialize and encrypt the local identity keys + username.
    /// - Parameters:
    ///   - identity: The local `IdentityManager` holding keypair and username.
    ///   - passphrase: User-supplied passphrase (min 12 chars — enforced in UI).
    /// - Returns: Raw encrypted blob suitable for file export / share sheet.
    public static func export(identity: IdentityManager, passphrase: String) throws -> Data {
        let sigKey = try identity.signingPrivateKeyData()
        let dhKey  = try identity.dhPrivateKeyData()
        let uname  = identity.publicIdentity.username

        let payload = IdentityPayload(
            signingKeyPrivate: sigKey,
            dhKeyPrivate:      dhKey,
            username:          uname,
            exportedAt:        Date()
        )
        let json   = try JSONEncoder().encode(payload)
        let salt   = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let key    = try deriveKey(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else {
            throw IdentityExportError.exportFailed("AES-GCM combined output unavailable")
        }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(fileVersion)
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
        let minSize = 4 + 1 + 32 + 12 + 16   // magic + version + salt + nonce + tag
        guard data.count > minSize else { throw IdentityExportError.corruptFile }
        let fileMagic = [UInt8](data[0..<4])
        guard fileMagic == magic else { throw IdentityExportError.corruptFile }
        // version byte at index 4 — reserved for future migration
        let salt     = data[5..<37]
        let combined = data[37...]

        let key = try deriveKey(passphrase: passphrase, salt: Data(salt))
        let json: Data
        do {
            let box = try AES.GCM.SealedBox(combined: Data(combined))
            json = try AES.GCM.open(box, using: key)
        } catch {
            throw IdentityExportError.wrongPassphrase
        }

        let payload: IdentityPayload
        do {
            payload = try JSONDecoder().decode(IdentityPayload.self, from: json)
        } catch {
            throw IdentityExportError.corruptFile
        }

        // Write private keys into Keychain (overwrites existing identity)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: payload.signingKeyPrivate)
        let dhKey      = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: payload.dhKeyPrivate)
        try keychain.saveSigningKey(signingKey)
        try keychain.saveDHIdentityKey(dhKey)
        try keychain.saveUsername(payload.username)

        // Zero-out sensitive data from memory
        var mutableSigning = payload.signingKeyPrivate
        var mutableDH      = payload.dhKeyPrivate
        mutableSigning.resetBytes(in: mutableSigning.startIndex..<mutableSigning.endIndex)
        mutableDH.resetBytes(in: mutableDH.startIndex..<mutableDH.endIndex)

        return payload.username
    }

    // MARK: - Suggested filename

    public static func suggestedFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "sophaxchat-identity-\(fmt.string(from: Date())).sophaxid"
    }

    // MARK: - Private: Key derivation

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        let passData = Data(passphrase.utf8)
        var derived  = Data(repeating: 0, count: 32)

        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                passData.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress, passData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdf2Iterations),
                        derivedPtr.baseAddress, 32
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw IdentityExportError.exportFailed("PBKDF2 derivation failed (\(status))")
        }
        return SymmetricKey(data: derived)
    }
}
