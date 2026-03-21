package com.sophax.sophaxchat

import android.content.Context
import androidx.lifecycle.ViewModel
import com.sophax.sophaxchat.crypto.IdentityManager
import com.sophax.sophaxchat.crypto.PreKeyManager
import com.sophax.sophaxchat.protocol.KnownPeer
import com.sophax.sophaxchat.storage.MessageStore
import com.sophax.sophaxchat.storage.StoredMessage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class AppState(private val context: Context) : ViewModel() {

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    private val prefs = context.getSharedPreferences("sophaxchat_prefs", Context.MODE_PRIVATE)

    private val _isSetupComplete = MutableStateFlow(prefs.getBoolean("setup_complete", false))
    val isSetupComplete: StateFlow<Boolean> = _isSetupComplete.asStateFlow()

    // -----------------------------------------------------------------------
    // Core objects (created lazily after setup)
    // -----------------------------------------------------------------------

    val identity   = IdentityManager(context)
    val messageStore = MessageStore(context)

    private var _chatManager: ChatManager? = null
    val chatManager: ChatManager? get() = _chatManager

    // -----------------------------------------------------------------------
    // UI state
    // -----------------------------------------------------------------------

    private val _peers = MutableStateFlow<List<KnownPeer>>(emptyList())
    val peers: StateFlow<List<KnownPeer>> = _peers.asStateFlow()

    private val _messages = MutableStateFlow<Map<String, List<StoredMessage>>>(emptyMap())
    val messages: StateFlow<Map<String, List<StoredMessage>>> = _messages.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // -----------------------------------------------------------------------
    // Setup flow
    // -----------------------------------------------------------------------

    fun createIdentity(username: String) {
        identity.setUsername(username)
        prefs.edit().putBoolean("setup_complete", true).apply()
        _isSetupComplete.value = true
        startChatManager()
    }

    fun startIfReady() {
        if (_isSetupComplete.value && _chatManager == null) {
            startChatManager()
        }
    }

    private fun startChatManager() {
        val preKeys = PreKeyManager(identity, context)
        val mgr = ChatManager(context, identity, preKeys, messageStore)
        mgr.delegate = object : ChatManagerDelegate {
            override fun didDiscoverPeer(peer: KnownPeer) {
                _peers.value = mgr.knownPeersList()
            }
            override fun peerDidDisconnect(peerID: String) {
                _peers.value = mgr.knownPeersList()
            }
            override fun didReceiveMessage(message: StoredMessage, fromPeerID: String) {
                _messages.value = _messages.value.toMutableMap().also {
                    it[fromPeerID] = mgr.messages(fromPeerID)
                }
            }
            override fun messageDelivered(messageID: String, toPeerID: String) {
                _messages.value = _messages.value.toMutableMap().also {
                    it[toPeerID] = mgr.messages(toPeerID)
                }
            }
            override fun didEncounterError(error: Exception) {
                _errorMessage.value = error.message
            }
        }
        _chatManager = mgr
        mgr.start()
    }

    // -----------------------------------------------------------------------
    // Message helpers
    // -----------------------------------------------------------------------

    fun sendMessage(toPeerID: String, body: String) {
        _chatManager?.sendMessage(toPeerID, body)
        // Refresh local messages immediately
        _messages.value = _messages.value.toMutableMap().also {
            it[toPeerID] = messageStore.loadMessages(toPeerID)
        }
    }

    fun messagesFor(peerID: String): List<StoredMessage> =
        _messages.value[peerID] ?: messageStore.loadMessages(peerID).also { msgs ->
            _messages.value = _messages.value.toMutableMap().also { it[peerID] = msgs }
        }

    override fun onCleared() {
        super.onCleared()
        _chatManager?.stop()
    }
}
