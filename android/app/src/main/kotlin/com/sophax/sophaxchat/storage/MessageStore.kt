package com.sophax.sophaxchat.storage

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.Date
import java.util.UUID

// ---------------------------------------------------------------------------
// Stored message model
// ---------------------------------------------------------------------------

enum class MessageDirection { sent, received }
enum class MessageStatus    { sending, delivered, failed, read }

@Serializable
data class StoredMessage(
    val id: String = UUID.randomUUID().toString(),
    val peerID: String,
    val direction: String,     // MessageDirection.name
    val body: String,
    val timestampMs: Long = System.currentTimeMillis(),
    var status: String = MessageStatus.sending.name,
    val replyToID: String? = null,
    val attachmentMimeType: String? = null
) {
    val timestamp: Date get() = Date(timestampMs)
    val isSent: Boolean get() = direction == MessageDirection.sent.name
}

// ---------------------------------------------------------------------------
// MessageStore — encrypted at rest via EncryptedSharedPreferences
// ---------------------------------------------------------------------------

class MessageStore(context: Context) {

    private val prefs: SharedPreferences = buildPrefs(context)
    private val json = Json { ignoreUnknownKeys = true }

    // -----------------------------------------------------------------------
    // Write
    // -----------------------------------------------------------------------

    fun store(message: StoredMessage) {
        val messages = loadMessages(message.peerID).toMutableList()
        val existingIndex = messages.indexOfFirst { it.id == message.id }
        if (existingIndex >= 0) {
            messages[existingIndex] = message
        } else {
            messages.add(message)
        }
        // Keep last 500 messages per conversation
        val trimmed = if (messages.size > 500) messages.takeLast(500) else messages
        prefs.edit()
            .putString(key(message.peerID), json.encodeToString(trimmed))
            .apply()
    }

    fun updateStatus(messageID: String, peerID: String, status: MessageStatus) {
        val messages = loadMessages(peerID).toMutableList()
        val index = messages.indexOfFirst { it.id == messageID }
        if (index >= 0) {
            messages[index] = messages[index].copy(status = status.name)
            prefs.edit().putString(key(peerID), json.encodeToString(messages)).apply()
        }
    }

    // -----------------------------------------------------------------------
    // Read
    // -----------------------------------------------------------------------

    fun loadMessages(peerID: String): List<StoredMessage> {
        val raw = prefs.getString(key(peerID), null) ?: return emptyList()
        return try {
            json.decodeFromString<List<StoredMessage>>(raw)
        } catch (e: Exception) { emptyList() }
    }

    fun allConversationIDs(): List<String> =
        prefs.all.keys
            .filter { it.startsWith("msgs_") }
            .map { it.removePrefix("msgs_") }

    // -----------------------------------------------------------------------
    // Delete
    // -----------------------------------------------------------------------

    fun deleteMessage(id: String, peerID: String) {
        val messages = loadMessages(peerID).filter { it.id != id }
        prefs.edit().putString(key(peerID), json.encodeToString(messages)).apply()
    }

    fun deleteConversation(peerID: String) {
        prefs.edit().remove(key(peerID)).apply()
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private fun key(peerID: String) = "msgs_$peerID"

    companion object {
        private fun buildPrefs(context: Context): SharedPreferences {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            return EncryptedSharedPreferences.create(
                context, "sophaxchat_messages", masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        }
    }
}
