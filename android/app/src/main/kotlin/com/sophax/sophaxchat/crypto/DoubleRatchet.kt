package com.sophax.sophaxchat.crypto

import com.google.crypto.tink.subtle.ChaCha20Poly1305
import com.google.crypto.tink.subtle.Hkdf
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

// ---------------------------------------------------------------------------
// Wire structures (must match iOS RatchetHeader / RatchetMessage exactly)
// ---------------------------------------------------------------------------

data class RatchetHeader(
    val senderRatchetKey: ByteArray,       // 32 bytes, base64 in JSON
    val previousChainLength: Long,         // UInt32 in iOS
    val messageNumber: Long                // UInt32 in iOS
)

data class RatchetMessage(
    val encryptedHeader: ByteArray,   // ChaCha20-Poly1305: nonce(12)+ct+tag(16)
    val ciphertext: ByteArray         // ChaCha20-Poly1305: nonce(12)+ct+tag(16)
)

// ---------------------------------------------------------------------------
// Session state (persisted between app restarts)
// ---------------------------------------------------------------------------

data class RatchetSessionState(
    var sendingRatchetPrivateKey: ByteArray,
    var sendingRatchetPublicKey: ByteArray,
    var receivingRatchetPublicKey: ByteArray?,
    var rootKey: ByteArray,
    var sendingChainKey: ByteArray?,
    var receivingChainKey: ByteArray?,
    var sendMessageCount: Long = 0,
    var receiveMessageCount: Long = 0,
    var previousSendingChainLength: Long = 0,
    var sendingHeaderKey: ByteArray?,
    var receivingHeaderKey: ByteArray?,
    var nextSendingHeaderKey: ByteArray?,
    var nextReceivingHeaderKey: ByteArray?,
    // skippedKeyBundles: base64(HKr) → msgNumStr → messageKey
    var skippedKeyBundles: MutableMap<String, MutableMap<String, ByteArray>> = mutableMapOf()
)

// ---------------------------------------------------------------------------
// Serializable helper for ratchet header JSON (avoids fragile substringAfter)
// ---------------------------------------------------------------------------

@Serializable
private data class RatchetHeaderJson(
    val senderRatchetKey: String,   // Base64-encoded 32 bytes
    val previousChainLength: Long,
    val messageNumber: Long
)

// ---------------------------------------------------------------------------
// Double Ratchet with Header Encryption
// Matches iOS implementation byte-for-byte.
// ---------------------------------------------------------------------------

class DoubleRatchet(private var state: RatchetSessionState) {

    // -----------------------------------------------------------------------
    // Initiator (Alice)
    // -----------------------------------------------------------------------

    companion object {
        fun initAsInitiator(sharedSecret: ByteArray, remoteRatchetPublicKey: ByteArray): DoubleRatchet {
            val sendingPair = generateDHKeyPair()

            val hks  = deriveHeaderKey(sharedSecret, CryptoConstants.HK_ALICE_INFO)
            val nhkr = deriveHeaderKey(sharedSecret, CryptoConstants.NHK_BOB_INFO)

            val dhOut = x25519(sendingPair.privateKeyBytes, remoteRatchetPublicKey)
            val (newRootKey, sendingCK, nhks) = kdfRK(sharedSecret, dhOut)

            val state = RatchetSessionState(
                sendingRatchetPrivateKey  = sendingPair.privateKeyBytes,
                sendingRatchetPublicKey   = sendingPair.publicKeyBytes,
                receivingRatchetPublicKey = remoteRatchetPublicKey,
                rootKey                   = newRootKey,
                sendingChainKey           = sendingCK,
                receivingChainKey         = null,
                sendingHeaderKey          = hks,
                receivingHeaderKey        = null,
                nextSendingHeaderKey      = nhks,
                nextReceivingHeaderKey    = nhkr
            )
            return DoubleRatchet(state)
        }

        // -----------------------------------------------------------------------
        // Responder (Bob)
        // -----------------------------------------------------------------------

        fun initAsResponder(sharedSecret: ByteArray, ownRatchetKeyPair: DHKeyPair): DoubleRatchet {
            val nhkr = deriveHeaderKey(sharedSecret, CryptoConstants.HK_ALICE_INFO)
            val nhks = deriveHeaderKey(sharedSecret, CryptoConstants.NHK_BOB_INFO)

            val state = RatchetSessionState(
                sendingRatchetPrivateKey  = ownRatchetKeyPair.privateKeyBytes,
                sendingRatchetPublicKey   = ownRatchetKeyPair.publicKeyBytes,
                receivingRatchetPublicKey = null,
                rootKey                   = sharedSecret,
                sendingChainKey           = null,
                receivingChainKey         = null,
                sendingHeaderKey          = null,
                receivingHeaderKey        = null,
                nextSendingHeaderKey      = nhks,
                nextReceivingHeaderKey    = nhkr
            )
            return DoubleRatchet(state)
        }

        // -----------------------------------------------------------------------
        // KDF_RK: HKDF-SHA256(salt=rootKey, IKM=dhOut, info=rkInfo, len=96)
        // Returns (newRootKey, chainKey, headerKey) — matches iOS exactly
        // -----------------------------------------------------------------------

        fun kdfRK(rootKey: ByteArray, dhOutput: ByteArray): Triple<ByteArray, ByteArray, ByteArray> {
            val derived = Hkdf.computeHkdf("HMACSHA256", dhOutput, rootKey, CryptoConstants.ROOT_KEY_INFO, 96)
            check(derived.size == 96) { "kdfRK: HKDF returned ${derived.size} bytes, expected 96" }
            return Triple(derived.sliceArray(0..31), derived.sliceArray(32..63), derived.sliceArray(64..95))
        }

        // -----------------------------------------------------------------------
        // KDF_CK: HMAC-SHA256
        //   newChainKey = HMAC(chainKey, 0x02)
        //   messageKey  = HMAC(chainKey, 0x01)
        // -----------------------------------------------------------------------

        fun kdfCK(chainKey: ByteArray): Pair<ByteArray, ByteArray> {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(chainKey, "HmacSHA256"))
            val newCK = mac.doFinal(byteArrayOf(0x02))
            mac.init(SecretKeySpec(chainKey, "HmacSHA256"))
            val mk    = mac.doFinal(byteArrayOf(0x01))
            return Pair(newCK, mk)
        }

        private fun deriveHeaderKey(sharedSecret: ByteArray, info: ByteArray): ByteArray =
            Hkdf.computeHkdf("HMACSHA256", sharedSecret, ByteArray(32), info, 32)
    }

    // -----------------------------------------------------------------------
    // Encrypt
    // -----------------------------------------------------------------------

    fun encrypt(plaintext: ByteArray, associatedData: ByteArray = ByteArray(0)): RatchetMessage {
        val ck  = state.sendingChainKey  ?: throw SophaxError.EncryptionFailed("no sending chain key")
        val hks = state.sendingHeaderKey ?: throw SophaxError.EncryptionFailed("no sending header key")

        val (newCK, mk) = kdfCK(ck)
        state.sendingChainKey = newCK

        val header = RatchetHeader(
            senderRatchetKey    = state.sendingRatchetPublicKey,
            previousChainLength = state.previousSendingChainLength,
            messageNumber       = state.sendMessageCount
        )
        state.sendMessageCount++

        val encryptedHeader = encryptHeader(header, hks)
        val ciphertext = encryptBody(mk, plaintext, encryptedHeader, associatedData)
        mk.fill(0)  // zero message key — prevents heap dump exposure
        return RatchetMessage(encryptedHeader, ciphertext)
    }

    // -----------------------------------------------------------------------
    // Decrypt
    // -----------------------------------------------------------------------

    fun decrypt(message: RatchetMessage, associatedData: ByteArray = ByteArray(0)): ByteArray {
        // 1. Check skipped keys
        decryptWithSkippedKey(message, associatedData)?.let { return it }

        // 2. Try current receiving header key
        state.receivingHeaderKey?.let { hkr ->
            decryptHeaderBytes(message.encryptedHeader, hkr)?.let { header ->
                skipMessageKeys(header.messageNumber)
                val ck = state.receivingChainKey ?: throw SophaxError.DecryptionFailed("no recv chain key")
                val (newCK, mk) = kdfCK(ck)
                state.receivingChainKey = newCK
                state.receiveMessageCount++
                val result = decryptBody(mk, message, associatedData)
                mk.fill(0)  // zero message key — prevents heap dump exposure
                return result
            }
        }

        // 3. Try next receiving header key → DH ratchet step
        val nhkr = state.nextReceivingHeaderKey ?: throw SophaxError.DecryptionFailed("no NHKr")
        val header = decryptHeaderBytes(message.encryptedHeader, nhkr)
            ?: throw SophaxError.DecryptionFailed("cannot decrypt header")

        skipMessageKeys(header.previousChainLength)
        dhRatchetStep(header.senderRatchetKey)
        skipMessageKeys(header.messageNumber)

        val ck = state.receivingChainKey ?: throw SophaxError.DecryptionFailed("no recv chain key after ratchet")
        val (newCK, mk) = kdfCK(ck)
        state.receivingChainKey = newCK
        state.receiveMessageCount++
        val decrypted = decryptBody(mk, message, associatedData)
        mk.fill(0)  // zero message key — prevents heap dump exposure
        return decrypted
    }

    // -----------------------------------------------------------------------
    // DH Ratchet Step
    // -----------------------------------------------------------------------

    private fun dhRatchetStep(remoteRatchetPublicKey: ByteArray) {
        state.previousSendingChainLength = state.sendMessageCount
        state.sendMessageCount           = 0
        state.receiveMessageCount        = 0

        state.sendingHeaderKey   = state.nextSendingHeaderKey
        state.receivingHeaderKey = state.nextReceivingHeaderKey

        state.receivingRatchetPublicKey = remoteRatchetPublicKey

        // Step 1: DH(current_sending, new_remote) → receiving chain key + NHKr
        val dh1 = x25519(state.sendingRatchetPrivateKey, remoteRatchetPublicKey)
        val (rk1, receivingCK, newNHKr) = kdfRK(state.rootKey, dh1)
        dh1.fill(0)   // zero DH output immediately — prevents memory-dump exposure
        state.rootKey                = rk1
        state.receivingChainKey      = receivingCK
        state.nextReceivingHeaderKey = newNHKr

        // Step 2: Generate new sending ratchet key pair
        val newSendingPair = generateDHKeyPair()
        state.sendingRatchetPrivateKey = newSendingPair.privateKeyBytes
        state.sendingRatchetPublicKey  = newSendingPair.publicKeyBytes

        // Step 3: DH(new_sending, new_remote) → sending chain key + NHKs
        val dh2 = x25519(newSendingPair.privateKeyBytes, remoteRatchetPublicKey)
        val (rk2, sendingCK, newNHKs) = kdfRK(rk1, dh2)
        dh2.fill(0)   // zero DH output immediately
        state.rootKey              = rk2
        state.sendingChainKey      = sendingCK
        state.nextSendingHeaderKey = newNHKs
    }

    // -----------------------------------------------------------------------
    // Skip message keys (out-of-order delivery)
    // -----------------------------------------------------------------------

    private fun skipMessageKeys(target: Long) {
        val ck = state.receivingChainKey ?: return
        // Use Long arithmetic throughout to avoid Int overflow when the gap
        // exceeds Int.MAX_VALUE (a malicious peer could otherwise bypass the
        // bounds check by sending a message with a very large message number).
        val totalSkipped = target - state.receiveMessageCount
        if (totalSkipped <= 0L) return

        val totalStored = state.skippedKeyBundles.values.sumOf { it.size }.toLong()
        if (totalStored + totalSkipped > CryptoConstants.MAX_SKIPPED_MESSAGES.toLong()) {
            throw SophaxError.DecryptionFailed("too many skipped messages")
        }

        val hkrB64 = state.receivingHeaderKey?.let {
            android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP)
        } ?: ""

        var chainKey = ck
        while (state.receiveMessageCount < target) {
            val (newCK, mk) = kdfCK(chainKey)
            state.skippedKeyBundles
                .getOrPut(hkrB64) { mutableMapOf() }["${state.receiveMessageCount}"] = mk
            chainKey = newCK
            state.receiveMessageCount++
        }
        state.receivingChainKey = chainKey
    }

    // -----------------------------------------------------------------------
    // Skipped key decryption
    // -----------------------------------------------------------------------

    private fun decryptWithSkippedKey(message: RatchetMessage, associatedData: ByteArray): ByteArray? {
        for ((headerKeyB64, bundle) in state.skippedKeyBundles) {
            val headerKeyBytes = android.util.Base64.decode(headerKeyB64, android.util.Base64.NO_WRAP)
            val header = decryptHeaderBytes(message.encryptedHeader, headerKeyBytes) ?: continue
            val msgNumStr = "${header.messageNumber}"
            val skippedMK = bundle[msgNumStr] ?: continue
            bundle.remove(msgNumStr)
            if (bundle.isEmpty()) state.skippedKeyBundles.remove(headerKeyB64)
            return decryptBody(skippedMK, message, associatedData)
        }
        return null
    }

    // -----------------------------------------------------------------------
    // Header crypto — ChaCha20-Poly1305 (nonce 12B + ct + tag 16B)
    // -----------------------------------------------------------------------

    private fun encryptHeader(header: RatchetHeader, key: ByteArray): ByteArray {
        val h = RatchetHeaderJson(
            senderRatchetKey    = android.util.Base64.encodeToString(header.senderRatchetKey, android.util.Base64.NO_WRAP),
            previousChainLength = header.previousChainLength,
            messageNumber       = header.messageNumber
        )
        return ChaCha20Poly1305(key).encrypt(Json.encodeToString(h).toByteArray(), ByteArray(0))
    }

    private fun decryptHeaderBytes(encryptedHeader: ByteArray, key: ByteArray): RatchetHeader? {
        return try {
            val headerJson = ChaCha20Poly1305(key).decrypt(encryptedHeader, ByteArray(0))
            val h = Json.decodeFromString<RatchetHeaderJson>(String(headerJson))
            RatchetHeader(
                senderRatchetKey    = android.util.Base64.decode(h.senderRatchetKey, android.util.Base64.NO_WRAP),
                previousChainLength = h.previousChainLength,
                messageNumber       = h.messageNumber
            )
        } catch (e: Exception) { null }
    }

    // -----------------------------------------------------------------------
    // Body crypto
    // -----------------------------------------------------------------------

    private fun encryptBody(mk: ByteArray, plaintext: ByteArray, encryptedHeader: ByteArray, associatedData: ByteArray): ByteArray {
        val aad = associatedData + encryptedHeader
        return ChaCha20Poly1305(mk).encrypt(plaintext, aad)
    }

    private fun decryptBody(mk: ByteArray, message: RatchetMessage, associatedData: ByteArray): ByteArray {
        val aad = associatedData + message.encryptedHeader
        return try {
            ChaCha20Poly1305(mk).decrypt(message.ciphertext, aad)
        } catch (e: Exception) {
            throw SophaxError.DecryptionFailed("body decryption failed: ${e.message}")
        }
    }
}
