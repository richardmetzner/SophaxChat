package com.sophax.sophaxchat.crypto

import com.sophax.sophaxchat.protocol.ByteArrayBase64
import kotlinx.serialization.Serializable
import java.util.UUID

// ---------------------------------------------------------------------------
// GroupInfo — persisted per group (matches iOS GroupInfo exactly)
// ---------------------------------------------------------------------------

@Serializable
data class GroupInfo(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val memberIDs: List<String>,
    val creatorID: String
) {
    /** Conversation ID used as key in MessageStore — matches iOS `"group.\(id)"` */
    val conversationID: String get() = "group.$id"
}

// ---------------------------------------------------------------------------
// GroupInvitePayload — sent via DR-encrypted .message to each invitee
// ---------------------------------------------------------------------------

@Serializable
data class GroupInvitePayload(
    val groupID: String,
    val groupName: String,
    val memberIDs: List<String>,
    val creatorID: String,
    // v2 Sender Keys
    val senderChainKey: ByteArrayBase64? = null,
    val senderIteration: Long? = null,
    // v1 shared key (backward compat)
    val groupKeyData: ByteArrayBase64? = null
)

// ---------------------------------------------------------------------------
// SenderKeyState — one sender's KDF chain per group
// Stored in EncryptedSharedPreferences under "skey_<groupID>_<peerID>"
// ---------------------------------------------------------------------------

@Serializable
data class SenderKeyState(
    val chainKey: ByteArrayBase64,   // 32 bytes
    val iteration: Long = 0L
) {
    /**
     * Advance the chain by one step.
     * messageKey  = HMAC-SHA256(chainKey, 0x01)
     * nextChain   = HMAC-SHA256(chainKey, 0x02)
     * Matches iOS SenderKeys ratchet exactly.
     */
    fun ratchet(): Pair<ByteArray, SenderKeyState> {
        val messageKey = hmacSha256(chainKey, byteArrayOf(0x01))
        val nextChain  = hmacSha256(chainKey, byteArrayOf(0x02))
        return Pair(messageKey, SenderKeyState(nextChain, iteration + 1))
    }

    /**
     * Fast-forward to a target iteration (for out-of-order messages).
     * Returns the message key at `targetIteration` and the state after it.
     */
    fun advanceTo(targetIteration: Long): Pair<ByteArray, SenderKeyState> {
        var state = this
        var mk    = chainKey
        while (state.iteration < targetIteration) {
            val (m, next) = state.ratchet()
            mk    = m
            state = next
        }
        return Pair(mk, state)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        mac.init(javax.crypto.spec.SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }
}

// ---------------------------------------------------------------------------
// SenderKeyDistributionMessage — redistributed on membership change
// ---------------------------------------------------------------------------

@Serializable
data class SenderKeyDistributionMessage(
    val groupID: String,
    val chainKey: ByteArrayBase64,
    val iteration: Long
)
