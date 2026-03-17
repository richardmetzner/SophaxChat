// OnionAddress.swift
// SophaxChatCore
//
// Derives a Tor v3 .onion hostname from an Ed25519 public key.
//
// Tor v3 hidden service address spec (rend-spec-v3 §6):
//
//   onion_address = base32(pubkey || checksum || version) + ".onion"
//   checksum      = H(".onion checksum" || pubkey || version)[0:2]
//   version       = 0x03
//   H             = SHA3-256 (Keccak-256)
//
// The resulting address is 56 base32 characters + ".onion" = 62 chars total.
// Because it's derived from the signing key, it is stable and tied to identity.

import Foundation

public enum OnionAddress {

    public enum Error: Swift.Error {
        case invalidKeyLength(Int)
    }

    private static let version: UInt8   = 0x03
    private static let prefix           = ".onion checksum"

    /// Derives the Tor v3 `.onion` hostname (without port) from a 32-byte Ed25519 public key.
    /// Throws `OnionAddress.Error.invalidKeyLength` if the key is not exactly 32 bytes.
    public static func from(ed25519PublicKey pubkey: Data) throws -> String {
        guard pubkey.count == 32 else {
            throw Error.invalidKeyLength(pubkey.count)
        }

        // Checksum = SHA3-256(".onion checksum" || pubkey || 0x03)[0:2]
        var checksumInput = Data(prefix.utf8)
        checksumInput.append(pubkey)
        checksumInput.append(version)
        let checksum = Keccak.hash256(checksumInput).prefix(2)

        // Encode: pubkey(32) || checksum(2) || version(1) = 35 bytes → 56 base32 chars
        var payload = pubkey
        payload.append(contentsOf: checksum)
        payload.append(version)

        return base32Encode(payload) + ".onion"
    }

    // MARK: - Base32 (RFC 4648, no padding, lowercase)

    private static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var result = [Character]()
        result.reserveCapacity((data.count * 8 + 4) / 5)

        var buffer: UInt64 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1F)
                result.append(alphabet[index])
            }
        }
        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            result.append(alphabet[index])
        }
        return String(result)
    }
}
