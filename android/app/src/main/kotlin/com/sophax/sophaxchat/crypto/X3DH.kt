package com.sophax.sophaxchat.crypto

import com.google.crypto.tink.subtle.Hkdf

/**
 * Extended Triple Diffie-Hellman (X3DH) key agreement.
 *
 * Byte-for-byte compatible with iOS implementation:
 *   - IKM = 32×0xFF || DH1 || DH2 || DH3 [|| DH4]
 *   - HKDF-SHA256(salt=32×0x00, ikm, info="SophaxChat_X3DH_v1", len=32)
 *
 * Reference: https://signal.org/docs/specifications/x3dh/
 */
object X3DH {

    data class SenderResult(
        val sharedSecret: ByteArray,         // 32 bytes
        val ephemeralPublicKey: ByteArray,   // 32 bytes — send to Bob
        val usedOneTimePreKeyId: UInt?       // nil if no OPK used
    )

    // -----------------------------------------------------------------------
    // Alice (initiator)
    // -----------------------------------------------------------------------

    fun initiateSender(
        senderIdentityDH: DHKeyPair,
        recipientBundle: PreKeyBundleLocal
    ): SenderResult {
        // Generate ephemeral key pair
        val ephemeral = generateDHKeyPair()

        // DH1 = DH(IK_A, SPK_B)
        val dh1 = x25519(senderIdentityDH.privateKeyBytes, recipientBundle.signedPreKeyPublic)
        // DH2 = DH(EK_A, IK_B)
        val dh2 = x25519(ephemeral.privateKeyBytes, recipientBundle.dhIdentityKeyPublic)
        // DH3 = DH(EK_A, SPK_B)
        val dh3 = x25519(ephemeral.privateKeyBytes, recipientBundle.signedPreKeyPublic)

        val dhConcat = dh1 + dh2 + dh3

        var usedOTPKId: UInt? = null
        val finalConcat = if (recipientBundle.oneTimePreKeyPublic != null &&
                              recipientBundle.oneTimePreKeyId != null) {
            val dh4 = x25519(ephemeral.privateKeyBytes, recipientBundle.oneTimePreKeyPublic)
            usedOTPKId = recipientBundle.oneTimePreKeyId
            dhConcat + dh4
        } else {
            dhConcat
        }

        val sharedSecret = deriveSharedSecret(finalConcat)
        return SenderResult(sharedSecret, ephemeral.publicKeyBytes, usedOTPKId)
    }

    // -----------------------------------------------------------------------
    // Bob (receiver)
    // -----------------------------------------------------------------------

    fun initiateReceiver(
        recipientIdentityDH: DHKeyPair,
        recipientSignedPreKey: DHKeyPair,
        recipientOneTimePreKey: DHKeyPair?,
        senderIdentityDHKeyBytes: ByteArray,   // IK_A public
        senderEphemeralKeyBytes: ByteArray     // EK_A public
    ): ByteArray {
        // DH1 = DH(SPK_B, IK_A)
        val dh1 = x25519(recipientSignedPreKey.privateKeyBytes, senderIdentityDHKeyBytes)
        // DH2 = DH(IK_B, EK_A)
        val dh2 = x25519(recipientIdentityDH.privateKeyBytes, senderEphemeralKeyBytes)
        // DH3 = DH(SPK_B, EK_A)
        val dh3 = x25519(recipientSignedPreKey.privateKeyBytes, senderEphemeralKeyBytes)

        val dhConcat = dh1 + dh2 + dh3

        val finalConcat = if (recipientOneTimePreKey != null) {
            val dh4 = x25519(recipientOneTimePreKey.privateKeyBytes, senderEphemeralKeyBytes)
            dhConcat + dh4
        } else {
            dhConcat
        }

        return deriveSharedSecret(finalConcat)
    }

    // -----------------------------------------------------------------------
    // KDF — matches iOS exactly
    // -----------------------------------------------------------------------

    /**
     * HKDF-SHA256:
     *   IKM  = 32×0xFF || dhConcat
     *   salt = 32×0x00
     *   info = "SophaxChat_X3DH_v1"
     *   len  = 32
     */
    private fun deriveSharedSecret(dhConcat: ByteArray): ByteArray {
        val ikm  = CryptoConstants.X3DH_PREFIX + dhConcat
        val salt = ByteArray(32) { 0x00 }
        return Hkdf.computeHkdf("HMACSHA256", ikm, salt, CryptoConstants.X3DH_INFO, 32)
    }
}

/** Minimal local representation of a peer's prekey bundle (for X3DH). */
data class PreKeyBundleLocal(
    val dhIdentityKeyPublic: ByteArray,
    val signedPreKeyPublic: ByteArray,
    val oneTimePreKeyPublic: ByteArray?,
    val oneTimePreKeyId: UInt?
)
