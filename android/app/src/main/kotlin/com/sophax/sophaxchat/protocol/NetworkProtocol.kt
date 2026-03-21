package com.sophax.sophaxchat.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import android.util.Base64
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// ---------------------------------------------------------------------------
// Custom serializers — match iOS JSONEncoder defaults
// ---------------------------------------------------------------------------

/** Serializes ByteArray as base64 (standard encoding, no wrap) — matches Swift Data Codable. */
object ByteArraySerializer : KSerializer<ByteArray> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("ByteArray", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) =
        encoder.encodeString(Base64.encodeToString(value, Base64.NO_WRAP))
    override fun deserialize(decoder: Decoder): ByteArray =
        Base64.decode(decoder.decodeString(), Base64.NO_WRAP)
}

/** Serializes Date as ISO8601 string — matches Swift's .iso8601 date strategy. */
object DateSerializer : KSerializer<Date> {
    private val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US).also {
        it.timeZone = TimeZone.getTimeZone("UTC")
    }
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("Date", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Date) =
        encoder.encodeString(fmt.format(value))
    override fun deserialize(decoder: Decoder): Date =
        fmt.parse(decoder.decodeString()) ?: Date()
}

typealias ByteArrayBase64 = @Serializable(ByteArraySerializer::class) ByteArray
typealias SerDate = @Serializable(DateSerializer::class) Date

// ---------------------------------------------------------------------------
// Wire message envelope
// ---------------------------------------------------------------------------

enum class WireMessageType {
    hello, initiateSession, message, ack, relay, typing,
    sealed, readReceipt, reaction,
    groupMessage, groupReaction, groupMemberLeft, groupReadReceipt,
    storeAndForward, storeAndForwardDelivery, channelAnnouncement
}

@Serializable
data class WireMessage(
    val type: String,                              // WireMessageType.name
    val payload: ByteArrayBase64,
    val senderID: String,
    val timestamp: SerDate,
    val signature: ByteArrayBase64
) {
    /** Canonical bytes for signing — must match iOS signingBytes(). */
    fun signingBytes(): ByteArray =
        type.toByteArray() + payload +
        senderID.toByteArray() +
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US).let {
            it.timeZone = TimeZone.getTimeZone("UTC")
            it.format(timestamp).toByteArray()
        }
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

@Serializable
data class PreKeyBundle(
    val peerID: String,
    val username: String,
    val signingKeyPublic: ByteArrayBase64,
    val dhIdentityKeyPublic: ByteArrayBase64,
    val signedPreKeyPublic: ByteArrayBase64,
    val signedPreKeyId: Long,
    val signedPreKeySignature: ByteArrayBase64,
    val oneTimePreKeyPublic: ByteArrayBase64?,
    val oneTimePreKeyId: Long?,
    val timestamp: SerDate,
    val tcpAddress: String?
)

@Serializable
data class HelloMessage(val bundle: PreKeyBundle)

// ---------------------------------------------------------------------------
// Session initiation (X3DH)
// ---------------------------------------------------------------------------

@Serializable
data class RatchetHeader(
    val senderRatchetKey: ByteArrayBase64,
    val previousChainLength: Long,
    val messageNumber: Long
)

@Serializable
data class RatchetMessage(
    val encryptedHeader: ByteArrayBase64,
    val ciphertext: ByteArrayBase64
)

@Serializable
data class InitiateSessionMessage(
    val senderBundle: PreKeyBundle,
    val ephemeralPublicKey: ByteArrayBase64,
    val usedSignedPreKeyId: Long,
    val usedOneTimePreKeyId: Long?,
    val initialMessage: RatchetMessage
)

// ---------------------------------------------------------------------------
// Chat message
// ---------------------------------------------------------------------------

@Serializable
data class ChatMessagePayload(
    val ratchetMessage: RatchetMessage,
    val messageID: String
)

@Serializable
data class MessageContent(
    val body: String,
    val type: String = "text",            // text | image | audio | groupInvite | senderKeyDistribution
    val replyToID: String? = null,
    val timestamp: SerDate,
    val expiresAt: SerDate? = null,
    val attachmentData: ByteArrayBase64? = null,
    val attachmentMimeType: String? = null,
    val audioDuration: Double? = null,
    val groupInviteData: ByteArrayBase64? = null,
    val senderKeyData: ByteArrayBase64? = null
)

// ---------------------------------------------------------------------------
// Ack
// ---------------------------------------------------------------------------

@Serializable
data class AckMessage(val messageID: String, val status: String)  // "delivered" | "failed"

// ---------------------------------------------------------------------------
// Typing
// ---------------------------------------------------------------------------

@Serializable
data class TypingMessage(val isTyping: Boolean)

// ---------------------------------------------------------------------------
// Read receipt
// ---------------------------------------------------------------------------

@Serializable
data class ReadReceiptMessage(val messageIDs: List<String>)

// ---------------------------------------------------------------------------
// Reactions
// ---------------------------------------------------------------------------

@Serializable
data class ReactionMessage(val targetMessageID: String, val emoji: String?)

@Serializable
data class GroupReactionMessage(val groupID: String, val targetMessageID: String, val emoji: String?)

// ---------------------------------------------------------------------------
// Multihop relay
// ---------------------------------------------------------------------------

@Serializable
data class RelayEnvelope(
    val id: String,
    val targetPeerID: String,
    val originPeerID: String,
    val ttl: Int,
    val hopCount: Int,
    val message: WireMessage
) {
    companion object { const val MAX_TTL = 6 }

    fun forwarded() = copy(ttl = if (ttl > 0) ttl - 1 else 0, hopCount = hopCount + 1)
}

// ---------------------------------------------------------------------------
// Sealed sender
// ---------------------------------------------------------------------------

@Serializable
data class SealedMessage(
    val ephemeralPublicKey: ByteArrayBase64,
    val encryptedPayload: ByteArrayBase64
)

// ---------------------------------------------------------------------------
// Group messages
// ---------------------------------------------------------------------------

@Serializable
data class GroupWireMessage(
    val groupID: String,
    val messageID: String,
    val senderPeerID: String,
    val senderUsername: String,
    val timestamp: SerDate,
    val ciphertext: ByteArrayBase64,
    val attachmentCiphertext: ByteArrayBase64? = null,
    val attachmentMimeType: String? = null,
    val audioDuration: Double? = null,
    val senderKeyIteration: Long? = null,
    val expiresAt: SerDate? = null,
    val replyToID: String? = null
)

@Serializable
data class GroupMemberLeftMessage(
    val groupID: String,
    val leavingPeerID: String,
    val remainingMemberIDs: List<String>
)

@Serializable
data class GroupReadReceiptMessage(val groupID: String, val targetMessageID: String)

// ---------------------------------------------------------------------------
// Store-and-forward
// ---------------------------------------------------------------------------

@Serializable
data class StoreAndForwardRequest(
    val targetPeerID: String,
    val messageID: String,
    val sealed: SealedMessage,
    val expiresAt: SerDate
)

@Serializable
data class StoreAndForwardDelivery(val items: List<StoreAndForwardItem>)

@Serializable
data class StoreAndForwardItem(val messageID: String, val sealed: SealedMessage)

// ---------------------------------------------------------------------------
// Channel discovery
// ---------------------------------------------------------------------------

@Serializable
data class ChannelAnnouncement(
    val groupID: String,
    val groupName: String,
    val creatorID: String,
    val memberCount: Int,
    val timestamp: SerDate
)

// ---------------------------------------------------------------------------
// Known peer (local store)
// ---------------------------------------------------------------------------

data class KnownPeer(
    val id: String,
    val username: String,
    val signingKeyPublic: ByteArray,
    val dhKeyPublic: ByteArray,
    val safetyNumber: String,
    var lastSeen: Date? = null,
    var isOnline: Boolean = false,
    var isDirectlyConnected: Boolean = false,
    var tcpAddress: String? = null
)
