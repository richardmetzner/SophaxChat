// HiddenServiceKeyWriter.swift
// SophaxChat
//
// Writes a deterministic Tor v3 hidden service key file from an Ed25519 identity seed.
//
// By pre-writing the key file before Tor starts, we guarantee that the hidden service
// .onion address equals OnionAddress.from(ed25519PublicKey:) — i.e. the address is a
// stable function of the user's identity key, requiring no out-of-band communication.
//
// Tor v3 hidden service key file format (`hs_ed25519_secret_key`):
//   [0..31]  = "== ed25519v1-secret: type0 ==\0\0\0"  (fixed ASCII header, 29 bytes + 3 NUL)
//   [32..95] = expanded Ed25519 private key (64 bytes = SHA-512(seed) with clamping)
//
// Reference: torspec/rend-spec-v3.txt §A.2

import Foundation
import CryptoKit

enum HiddenServiceKeyWriter {

    // 32-byte ASCII header: "== ed25519v1-secret: type0 ==\0\0\0"
    private static let fileHeader: [UInt8] = {
        let ascii = Array("== ed25519v1-secret: type0 ==".utf8) // 29 bytes
        return ascii + [0, 0, 0]  // + 3 NUL bytes = 32 bytes total
    }()

    /// Writes `hs_ed25519_secret_key` and `hs_ed25519_public_key` into `directory`.
    /// Creates the directory if it doesn't exist. Safe to call repeatedly — overwrites.
    ///
    /// - Parameters:
    ///   - directory:  The hidden service directory (e.g. `<tor_data>/hidden_service/`).
    ///   - seed:       32-byte Ed25519 private key seed (raw representation of the signing key).
    static func write(to directory: URL, seed: Data) throws {
        precondition(seed.count == 32, "Ed25519 seed must be 32 bytes")

        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        // 1. Derive expanded private key: SHA-512(seed) with Ed25519 scalar clamping.
        let expanded = expandEd25519Seed(seed)

        // 2. Write secret key file (96 bytes).
        var secretFileBytes = [UInt8](fileHeader)  // 32-byte header
        secretFileBytes.append(contentsOf: expanded)  // 64-byte expanded key
        let secretKeyURL = directory.appendingPathComponent("hs_ed25519_secret_key")
        try Data(secretFileBytes).write(to: secretKeyURL, options: .atomic)

        // 3. Write public key file (64 bytes = same header + 32-byte public key).
        //    Tor reads this to verify the key pair; we derive it from the signing key.
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let pubkeyBytes = signingKey.publicKey.rawRepresentation
        var pubKeyFileBytes = [UInt8](fileHeader)
        pubKeyFileBytes.append(contentsOf: pubkeyBytes)
        let pubKeyURL = directory.appendingPathComponent("hs_ed25519_public_key")
        try Data(pubKeyFileBytes).write(to: pubKeyURL, options: .atomic)
    }

    // MARK: - Ed25519 seed expansion

    /// Expands a 32-byte Ed25519 seed into a 64-byte expanded private key via SHA-512,
    /// then applies the standard Ed25519 scalar clamping.
    private static func expandEd25519Seed(_ seed: Data) -> [UInt8] {
        // SHA-512(seed) → 64 bytes
        var h = Array(Data(SHA512.hash(data: seed)))

        // Ed25519 clamping (RFC 8032 §5.1.5):
        //   h[0]  &= 248   (clear the bottom 3 bits)
        //   h[31] &= 127   (clear the top bit)
        //   h[31] |= 64    (set the second-highest bit)
        h[0]  &= 248
        h[31] &= 127
        h[31] |= 64

        return h
    }
}
