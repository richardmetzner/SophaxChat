package com.sophax.sophaxchat.crypto

// ---------------------------------------------------------------------------
// Constants — must match iOS CryptoConstants exactly (same info strings)
// ---------------------------------------------------------------------------

object CryptoConstants {
    const val MAX_SKIPPED_MESSAGES = 1000

    // HKDF info strings — byte-for-byte identical to iOS
    val X3DH_INFO       = "SophaxChat_X3DH_v1".toByteArray()
    val ROOT_KEY_INFO   = "SophaxChat_RootKey_v1".toByteArray()
    val CHAIN_RATCHET_INFO  = "SophaxChat_ChainRatchet_v1".toByteArray()
    val ROOT_RATCHET_INFO   = "SophaxChat_RootRatchet_v1".toByteArray()
    val HK_ALICE_INFO   = "SophaxChat_HKAlice_v1".toByteArray()
    val NHK_BOB_INFO    = "SophaxChat_NHKBob_v1".toByteArray()
    val SENDER_KEY_MSG_INFO   = "SophaxChat_SenderKey_Message_v1".toByteArray()
    val SENDER_KEY_CHAIN_INFO = "SophaxChat_SenderKey_Chain_v1".toByteArray()
    val SEALED_SENDER_INFO    = "SophaxChat_SealedSender_v1".toByteArray()
    val STORAGE_INFO    = "SophaxChat_Storage_v1".toByteArray()
    val SESSION_INFO    = "SophaxChat_Session_v1".toByteArray()

    // X3DH: 32 × 0xFF prefix before DH outputs (matches iOS)
    val X3DH_PREFIX: ByteArray = ByteArray(32) { 0xFF.toByte() }

    const val KEY_SIZE = 32
    const val NONCE_SIZE = 12
    const val TAG_SIZE = 16
    const val SIGNATURE_SIZE = 64
}

// ---------------------------------------------------------------------------
// Key pair types
// ---------------------------------------------------------------------------

/** X25519 key pair for Diffie-Hellman operations. */
data class DHKeyPair(
    val privateKeyBytes: ByteArray,   // 32 bytes
    val publicKeyBytes: ByteArray     // 32 bytes
) {
    override fun equals(other: Any?): Boolean =
        other is DHKeyPair &&
        privateKeyBytes.contentEquals(other.privateKeyBytes) &&
        publicKeyBytes.contentEquals(other.publicKeyBytes)

    override fun hashCode(): Int =
        31 * privateKeyBytes.contentHashCode() + publicKeyBytes.contentHashCode()
}

/** Ed25519 key pair for signing. */
data class SigningKeyPair(
    val privateKeyBytes: ByteArray,   // 64 bytes (seed + public, BC format)
    val publicKeyBytes: ByteArray     // 32 bytes
) {
    override fun equals(other: Any?): Boolean =
        other is SigningKeyPair &&
        privateKeyBytes.contentEquals(other.privateKeyBytes) &&
        publicKeyBytes.contentEquals(other.publicKeyBytes)

    override fun hashCode(): Int =
        31 * privateKeyBytes.contentHashCode() + publicKeyBytes.contentHashCode()
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

sealed class SophaxError(message: String) : Exception(message) {
    class KeyGenerationFailed(detail: String = "") : SophaxError("Key generation failed: $detail")
    class SignatureFailed(detail: String = "") : SophaxError("Signature failed: $detail")
    class VerificationFailed(detail: String = "") : SophaxError("Verification failed: $detail")
    class EncryptionFailed(detail: String = "") : SophaxError("Encryption failed: $detail")
    class DecryptionFailed(detail: String = "") : SophaxError("Decryption failed: $detail")
    class KeyExchangeFailed(detail: String = "") : SophaxError("Key exchange failed: $detail")
    class StorageFailed(detail: String = "") : SophaxError("Storage failed: $detail")
    class InvalidInput(detail: String = "") : SophaxError("Invalid input: $detail")
    class SessionNotFound : SophaxError("No session found for peer")
    class NoPreKeysAvailable : SophaxError("No one-time prekeys available")
    class BundleTooOld : SophaxError("PreKeyBundle is too old")
}

// ---------------------------------------------------------------------------
// Extensions
// ---------------------------------------------------------------------------

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

fun ByteArray.xor(other: ByteArray): ByteArray {
    require(size == other.size) { "XOR requires equal-length arrays" }
    return ByteArray(size) { i -> (this[i].toInt() xor other[i].toInt()).toByte() }
}
