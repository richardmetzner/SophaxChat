// ShamirBackup.swift
// SophaxChatCore
//
// Shamir's Secret Sharing backup for identity private keys.
//
// Protocol overview:
//   • Creator splits their 64-byte identity secret (Ed25519 + X25519 private keys)
//     into N shares using (M, N) threshold SSS over GF(256).
//   • Each share is ECDH-encrypted for a specific trusted contact and delivered
//     via .sssShareDelivery wire message.
//   • Holder stores their plaintext share in the Keychain.
//   • Recovery: creator requests shares from M contacts via .sssShareRequest.
//     Contacts re-encrypt their stored share for the requester and respond
//     via .sssShareResponse. Creator reconstructs the secret from M shares.
//
// Crypto:
//   • SSS: GF(256) with irreducible polynomial x^8+x^4+x^3+x+1 (0x11B).
//   • Share encryption: X25519 ECDH → HKDF-SHA256 → ChaChaPoly (same as sealed sender).
//   • Share storage: iOS Keychain, kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
//
// Security properties:
//   • Any M−1 shares reveal zero information about the secret (information-theoretic).
//   • Shares in transit are E2E-encrypted; relay nodes see only ciphertext.
//   • Shares at rest are Keychain-protected (AES-256-GCM, device-only).

import Foundation
import CryptoKit

// MARK: - Types

/// One Shamir share — x-coordinate plus y-values for every secret byte.
public struct SSSShare: Codable, Sendable {
    /// UUID linking all N shares of a single backup instance.
    public let id: String
    /// x-coordinate in GF(256) — never 0. Range 1..N.
    public let index: UInt8
    /// Minimum shares required for reconstruction.
    public let threshold: UInt8
    /// Total shares created.
    public let total: UInt8
    /// One GF(256) y-value per secret byte — same length as the original secret.
    public let data: Data
    public let createdAt: Date
}

/// Creator's record of which trusted contacts hold which shares.
/// Stored in Keychain so the creator knows who to request recovery from.
public struct SSSBackupManifest: Codable, Sendable {
    /// UUID identifying the backup instance (matches `SSSShare.id`).
    public let shareID: String
    /// Minimum shares required for recovery.
    public let threshold: Int
    /// PeerIDs of share holders, in index order: holderPeerIDs[i] holds share index i+1.
    public let holderPeerIDs: [String]
    public let createdAt: Date
}

public enum ShamirBackupError: Error, LocalizedError {
    case invalidParameters(String)
    case notEnoughShares
    case inconsistentShares
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidParameters(let r): return "Invalid SSS parameters: \(r)"
        case .notEnoughShares:          return "Not enough shares to reconstruct the secret."
        case .inconsistentShares:       return "Shares belong to different backup instances."
        case .encryptionFailed:         return "Share encryption failed."
        case .decryptionFailed:         return "Share decryption failed."
        }
    }
}

// MARK: - ShamirBackup

public enum ShamirBackup {

    // MARK: - Public API

    /// Split `secret` into `n` shares with `m`-of-`n` threshold.
    /// - Parameters:
    ///   - secret: The bytes to protect (typically 64B: Ed25519 + X25519 private keys).
    ///   - m: Minimum shares needed to reconstruct (threshold). Must be ≥ 2.
    ///   - n: Total shares to generate. Must be ≥ m and ≤ 255.
    /// - Returns: Exactly `n` shares. Any `m` of them reconstruct `secret`.
    public static func split(secret: Data, m: Int, n: Int) throws -> [SSSShare] {
        guard m >= 2 else { throw ShamirBackupError.invalidParameters("threshold must be ≥ 2") }
        guard n >= m else { throw ShamirBackupError.invalidParameters("n must be ≥ m") }
        guard n <= 255 else { throw ShamirBackupError.invalidParameters("n must be ≤ 255") }
        guard !secret.isEmpty else { throw ShamirBackupError.invalidParameters("secret is empty") }

        let shareID = UUID().uuidString
        let now = Date()
        // shares[i][j] = share (i+1)'s y-value for secret byte j
        var shares = [[UInt8]](repeating: [UInt8](repeating: 0, count: secret.count), count: n)

        for (byteIdx, secretByte) in secret.enumerated() {
            // Random polynomial of degree m−1: f(x) = secretByte + a1*x + ... + a_{m-1}*x^{m-1}
            var coeffs = [UInt8](repeating: 0, count: m)
            coeffs[0] = secretByte
            for i in 1..<m {
                var rand: UInt8 = 0
                repeat { rand = UInt8.random(in: 0...255) } while i == m - 1 && rand == 0
                coeffs[i] = rand
            }
            for xi in 1...n {
                shares[xi - 1][byteIdx] = evalPoly(coeffs: coeffs, x: UInt8(xi))
            }
        }

        return (1...n).map { xi in
            SSSShare(
                id:        shareID,
                index:     UInt8(xi),
                threshold: UInt8(m),
                total:     UInt8(n),
                data:      Data(shares[xi - 1]),
                createdAt: now
            )
        }
    }

    /// Reconstruct the secret from any `share.threshold` (or more) shares.
    /// All shares must belong to the same backup instance (same `id`).
    public static func reconstruct(shares: [SSSShare]) throws -> Data {
        guard let first = shares.first else { throw ShamirBackupError.notEnoughShares }
        let m = Int(first.threshold)
        guard shares.count >= m else { throw ShamirBackupError.notEnoughShares }
        guard shares.allSatisfy({ $0.id == first.id && $0.data.count == first.data.count }) else {
            throw ShamirBackupError.inconsistentShares
        }
        let used = Array(shares.prefix(m))
        let xs   = used.map { $0.index }
        let secretLen = first.data.count
        var secret = [UInt8](repeating: 0, count: secretLen)
        for byteIdx in 0..<secretLen {
            let ys = used.map { $0.data[byteIdx] }
            secret[byteIdx] = lagrangeAt0(xs: xs, ys: ys)
        }
        return Data(secret)
    }

    // MARK: - Share encryption / decryption

    private static let hkdfInfo = Data("SophaxChat_SSS_Share_v1".utf8)

    /// Encrypt `share` for a recipient identified by `recipientDHPublicKey` (32B X25519).
    /// Returns (ephemeralPublicKey, ciphertext) to be sent in .sssShareDelivery.
    public static func encryptShare(_ share: SSSShare, recipientDHPublicKey: Data) throws -> (ephPublicKey: Data, ciphertext: Data) {
        let ephPair  = DHKeyPair()
        let recipKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientDHPublicKey)
        let shared   = try ephPair.privateKey.sharedSecretFromKeyAgreement(with: recipKey)

        var ikm = Data()
        shared.withUnsafeBytes { ikm.append(contentsOf: $0) }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            info: hkdfInfo,
            outputByteCount: 32
        )

        let plaintext = try JSONEncoder().encode(share)
        let sealed    = try ChaChaPoly.seal(plaintext, using: key)
        return (ephPublicKey: ephPair.publicKeyData, ciphertext: sealed.combined)
    }

    /// Decrypt a share received in .sssShareDelivery using the local X25519 private key.
    public static func decryptShare(
        ephPublicKey: Data,
        ciphertext:   Data,
        myDHPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> SSSShare {
        let ephKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPublicKey)
        let shared = try myDHPrivateKey.sharedSecretFromKeyAgreement(with: ephKey)

        var ikm = Data()
        shared.withUnsafeBytes { ikm.append(contentsOf: $0) }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            info: hkdfInfo,
            outputByteCount: 32
        )

        do {
            let box       = try ChaChaPoly.SealedBox(combined: ciphertext)
            let plaintext = try ChaChaPoly.open(box, using: key)
            return try JSONDecoder().decode(SSSShare.self, from: plaintext)
        } catch {
            throw ShamirBackupError.decryptionFailed
        }
    }

    // MARK: - GF(256) arithmetic
    // Irreducible polynomial: x^8 + x^4 + x^3 + x + 1 → reduction constant 0x1B.

    /// Multiplication in GF(256) via Russian-peasant method.
    static func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var p: UInt8 = 0
        var a = a, b = b
        for _ in 0..<8 {
            if b & 1 != 0 { p ^= a }
            let carry = a & 0x80 != 0
            a <<= 1
            if carry { a ^= 0x1B }
            b >>= 1
        }
        return p
    }

    /// Multiplicative inverse in GF(256): a^(2^8−2) = a^254 by Fermat's little theorem.
    static func gfInv(_ a: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        return gfPow(a, 254)
    }

    private static func gfPow(_ base: UInt8, _ exp: Int) -> UInt8 {
        var result: UInt8 = 1
        var base = base, exp = exp
        while exp > 0 {
            if exp & 1 != 0 { result = gfMul(result, base) }
            base = gfMul(base, base)
            exp >>= 1
        }
        return result
    }

    /// Evaluate polynomial (Horner's method) at `x` in GF(256).
    /// `coeffs[0]` is the constant term (= secret byte at x=0).
    private static func evalPoly(coeffs: [UInt8], x: UInt8) -> UInt8 {
        var result: UInt8 = 0
        for coeff in coeffs.reversed() {
            result = gfMul(result, x) ^ coeff
        }
        return result
    }

    /// Lagrange interpolation at x=0 in GF(256).
    /// Given `m` (x, y) pairs, returns f(0) = the secret byte.
    private static func lagrangeAt0(xs: [UInt8], ys: [UInt8]) -> UInt8 {
        var secret: UInt8 = 0
        let n = xs.count
        for i in 0..<n {
            var num: UInt8 = 1   // ∏ (0 − x_j) = ∏ x_j  (in GF, −x = x)
            var den: UInt8 = 1   // ∏ (x_i − x_j) = ∏ (x_i ⊕ x_j)
            for j in 0..<n where j != i {
                num = gfMul(num, xs[j])
                den = gfMul(den, xs[i] ^ xs[j])
            }
            // ys[i] * num * den^(−1)
            secret ^= gfMul(ys[i], gfMul(num, gfInv(den)))
        }
        return secret
    }
}
