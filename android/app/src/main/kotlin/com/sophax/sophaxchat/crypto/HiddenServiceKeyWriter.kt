package com.sophax.sophaxchat.crypto

// HiddenServiceKeyWriter.kt
// SophaxChat — Android
//
// Writes a deterministic Tor v3 hidden service key file from an Ed25519 identity seed.
// Kotlin port of iOS HiddenServiceKeyWriter.swift — must produce identical binary output.
//
// By pre-writing the key file before Tor starts, the .onion address equals
// OnionAddress.from(ed25519PublicKey) — stable and tied to the user's identity.
//
// Tor v3 hidden service key file format (`hs_ed25519_secret_key`):
//   [0..31]  = "== ed25519v1-secret: type0 ==\0\0\0"  (fixed ASCII header, 29 bytes + 3 NUL)
//   [32..95] = expanded Ed25519 private key (64 bytes = SHA-512(seed) with clamping)
//
// Reference: torspec/rend-spec-v3.txt §A.2

import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import java.io.File
import java.security.MessageDigest

object HiddenServiceKeyWriter {

    // Fixed 32-byte file header
    private val FILE_HEADER: ByteArray = run {
        val ascii = "== ed25519v1-secret: type0 ==".toByteArray(Charsets.US_ASCII) // 29 bytes
        ascii + byteArrayOf(0, 0, 0)  // + 3 NUL bytes = 32 bytes total
    }

    /**
     * Writes `hs_ed25519_secret_key` and `hs_ed25519_public_key` into [directory].
     * Creates the directory if it does not exist. Safe to call repeatedly — overwrites.
     *
     * @param directory  The hidden service directory (e.g. `<filesDir>/tor/hidden_service/`)
     * @param seed       32-byte Ed25519 private key seed
     */
    fun write(directory: File, seed: ByteArray) {
        require(seed.size == 32) { "Ed25519 seed must be 32 bytes, got ${seed.size}" }

        directory.mkdirs()

        // 1. Derive expanded private key: SHA-512(seed) with Ed25519 scalar clamping.
        val expanded = expandEd25519Seed(seed)

        // 2. Write secret key file (96 bytes).
        val secretFile = File(directory, "hs_ed25519_secret_key")
        secretFile.writeBytes(FILE_HEADER + expanded)

        // 3. Write public key file (64 bytes = same header + 32-byte public key).
        val privParams = Ed25519PrivateKeyParameters(seed)
        val pubKeyBytes = privParams.generatePublicKey().encoded  // 32 bytes
        val pubFile = File(directory, "hs_ed25519_public_key")
        pubFile.writeBytes(FILE_HEADER + pubKeyBytes)
    }

    // -------------------------------------------------------------------------
    // Ed25519 seed expansion (same as iOS expandEd25519Seed)

    /**
     * Expands a 32-byte Ed25519 seed into a 64-byte expanded private key via SHA-512,
     * then applies the standard Ed25519 scalar clamping (RFC 8032 §5.1.5).
     */
    private fun expandEd25519Seed(seed: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-512")
        val h = digest.digest(seed)  // 64 bytes

        // Ed25519 clamping:
        //   h[0]  &= 248   (clear the bottom 3 bits)
        //   h[31] &= 127   (clear the top bit)
        //   h[31] |= 64    (set the second-highest bit)
        h[0]  = (h[0].toInt()  and 0xF8).toByte()
        h[31] = (h[31].toInt() and 0x7F).toByte()
        h[31] = (h[31].toInt() or  0x40).toByte()

        return h
    }
}
