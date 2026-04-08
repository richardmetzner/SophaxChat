package com.sophax.sophaxchat.crypto

// OnionAddress.kt
// SophaxChat — Android
//
// Derives a Tor v3 .onion hostname from an Ed25519 public key.
// Matches iOS OnionAddress.swift — must produce identical output for cross-platform interop.
//
// Tor v3 hidden service address spec (rend-spec-v3 §6):
//
//   onion_address = base32(pubkey || checksum || version) + ".onion"
//   checksum      = SHA3-256(".onion checksum" || pubkey || version)[0:2]
//   version       = 0x03
//
// The resulting address is 56 base32 characters + ".onion" = 62 chars total.

import org.bouncycastle.crypto.digests.SHA3Digest

object OnionAddress {

    private const val VERSION: Byte = 0x03
    private const val CHECKSUM_PREFIX = ".onion checksum"

    /** Derives the Tor v3 `.onion` hostname (without port) from a 32-byte Ed25519 public key. */
    fun from(ed25519PublicKey: ByteArray): String {
        require(ed25519PublicKey.size == 32) {
            "Ed25519 public key must be 32 bytes, got ${ed25519PublicKey.size}"
        }

        // Checksum = SHA3-256(".onion checksum" || pubkey || 0x03)[0:2]
        val checksumInput = CHECKSUM_PREFIX.toByteArray(Charsets.US_ASCII) +
                ed25519PublicKey +
                byteArrayOf(VERSION)
        val checksum = sha3_256(checksumInput).copyOfRange(0, 2)

        // Encode: pubkey(32) || checksum(2) || version(1) = 35 bytes → 56 base32 chars
        val payload = ed25519PublicKey + checksum + byteArrayOf(VERSION)
        return base32Encode(payload) + ".onion"
    }

    // MARK: - SHA3-256 via BouncyCastle (Keccak-256 / SHA3-256 per FIPS 202)

    private fun sha3_256(data: ByteArray): ByteArray {
        val digest = SHA3Digest(256)
        digest.update(data, 0, data.size)
        val out = ByteArray(32)
        digest.doFinal(out, 0)
        return out
    }

    // MARK: - Base32 (RFC 4648, no padding, lowercase)

    private val ALPHABET = "abcdefghijklmnopqrstuvwxyz234567".toCharArray()

    private fun base32Encode(data: ByteArray): String {
        val result = StringBuilder((data.size * 8 + 4) / 5)
        var buffer: Long = 0
        var bitsLeft = 0
        for (byte in data) {
            buffer = (buffer shl 8) or (byte.toLong() and 0xFF)
            bitsLeft += 8
            while (bitsLeft >= 5) {
                bitsLeft -= 5
                result.append(ALPHABET[((buffer shr bitsLeft) and 0x1F).toInt()])
            }
        }
        if (bitsLeft > 0) {
            result.append(ALPHABET[((buffer shl (5 - bitsLeft)) and 0x1F).toInt()])
        }
        return result.toString()
    }
}
