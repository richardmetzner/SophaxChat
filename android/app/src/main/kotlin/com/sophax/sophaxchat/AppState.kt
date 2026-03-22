package com.sophax.sophaxchat

import android.content.Context
import androidx.lifecycle.ViewModel
import com.sophax.sophaxchat.crypto.GroupInfo
import com.sophax.sophaxchat.crypto.IdentityManager
import com.sophax.sophaxchat.crypto.PreKeyManager
import com.sophax.sophaxchat.notifications.NotificationHelper
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
    // Core objects
    // -----------------------------------------------------------------------

    val identity     = IdentityManager(context)
    val messageStore = MessageStore(context)

    private var _chatManager: ChatManager? = null
    val chatManager: ChatManager? get() = _chatManager

    val myPeerID: String get() = identity.publicIdentity.peerID

    // -----------------------------------------------------------------------
    // UI state
    // -----------------------------------------------------------------------

    private val _peers = MutableStateFlow<List<KnownPeer>>(emptyList())
    val peers: StateFlow<List<KnownPeer>> = _peers.asStateFlow()

    private val _messages = MutableStateFlow<Map<String, List<StoredMessage>>>(emptyMap())
    val messages: StateFlow<Map<String, List<StoredMessage>>> = _messages.asStateFlow()

    private val _groups = MutableStateFlow<List<GroupInfo>>(emptyList())
    val groups: StateFlow<List<GroupInfo>> = _groups.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Settings state
    private val _username = MutableStateFlow(prefs.getString("username", "") ?: "")
    val username: StateFlow<String> = _username.asStateFlow()

    private val _tcpEnabled = MutableStateFlow(prefs.getBoolean("tcp_enabled", false))
    val tcpEnabled: StateFlow<Boolean> = _tcpEnabled.asStateFlow()

    private val _socksProxy = MutableStateFlow(prefs.getString("socks_proxy", "") ?: "")
    val socksProxy: StateFlow<String> = _socksProxy.asStateFlow()

    private val _blockedPeers = MutableStateFlow<List<String>>(
        prefs.getStringSet("blocked_peers", emptySet())?.toList() ?: emptyList()
    )
    val blockedPeers: StateFlow<List<String>> = _blockedPeers.asStateFlow()

    // Unread counts (in-memory; reset on markAsRead)
    private val _unreadCounts = MutableStateFlow<Map<String, Int>>(emptyMap())
    val unreadCounts: StateFlow<Map<String, Int>> = _unreadCounts.asStateFlow()

    fun markAsRead(conversationID: String) {
        messageStore.markAllRead(conversationID)
        _unreadCounts.value = _unreadCounts.value.toMutableMap().also { it.remove(conversationID) }
    }

    // Typing indicators
    private val _typingPeers = MutableStateFlow<Set<String>>(emptySet())
    val typingPeers: StateFlow<Set<String>> = _typingPeers.asStateFlow()

    private val typingClearRunners = mutableMapOf<String, Runnable>()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    fun sendTyping(toPeerID: String) {
        _chatManager?.sendTyping(toPeerID)
    }

    // App Lock
    private val _isAppLocked = MutableStateFlow(false)
    val isAppLocked: StateFlow<Boolean> = _isAppLocked.asStateFlow()

    val appLockEnabled: Boolean
        get() = prefs.getBoolean("app_lock_enabled", false)

    fun lockApp() {
        if (!appLockEnabled) return
        _chatManager?.stop()
        _chatManager = null
        _isAppLocked.value = true
    }

    fun unlockApp() {
        _isAppLocked.value = false
        startIfReady()
    }

    fun setAppLockEnabled(enabled: Boolean) {
        prefs.edit().putBoolean("app_lock_enabled", enabled).apply()
    }

    // -----------------------------------------------------------------------
    // Notifications
    // -----------------------------------------------------------------------

    init {
        NotificationHelper.createChannel(context)
    }

    // -----------------------------------------------------------------------
    // Setup flow
    // -----------------------------------------------------------------------

    fun createIdentity(username: String) {
        identity.setUsername(username)
        prefs.edit()
            .putBoolean("setup_complete", true)
            .putString("username", username)
            .apply()
        _isSetupComplete.value = true
        _username.value = username
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

        // Apply TCP settings
        if (_tcpEnabled.value) {
            val proxy = _socksProxy.value
            if (proxy.isNotEmpty()) {
                val parts = proxy.split(":")
                if (parts.size == 2) {
                    mgr.tcp.setSocksProxy(parts[0], parts[1].toIntOrNull() ?: 9050)
                }
            }
        }

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
                _unreadCounts.value = _unreadCounts.value.toMutableMap().also {
                    it[fromPeerID] = (it[fromPeerID] ?: 0) + 1
                }
                val senderName = _peers.value.firstOrNull { it.id == fromPeerID }?.username
                    ?: fromPeerID.take(8)
                NotificationHelper.showMessage(
                    context,
                    title = senderName,
                    body = message.body,
                    conversationID = fromPeerID,
                    messageID = message.id
                )
            }
            override fun didReceiveGroupMessage(message: StoredMessage, group: GroupInfo) {
                _messages.value = _messages.value.toMutableMap().also {
                    it[group.conversationID] = messageStore.loadMessages(group.conversationID)
                }
                _groups.value = mgr.groupsList()
                _unreadCounts.value = _unreadCounts.value.toMutableMap().also {
                    it[group.conversationID] = (it[group.conversationID] ?: 0) + 1
                }
                val senderName = _peers.value.firstOrNull { it.id == message.peerID }?.username
                    ?: message.peerID.take(8)
                NotificationHelper.showMessage(
                    context,
                    title = group.name,
                    body = "$senderName: ${message.body}",
                    conversationID = group.conversationID,
                    messageID = message.id
                )
            }
            override fun messageDelivered(messageID: String, toPeerID: String) {
                _messages.value = _messages.value.toMutableMap().also {
                    it[toPeerID] = mgr.messages(toPeerID)
                }
            }
            override fun didEncounterError(error: Exception) {
                _errorMessage.value = error.message
            }
            override fun didUpdateTypingState(peerID: String, isTyping: Boolean) {
                typingClearRunners.remove(peerID)?.let { mainHandler.removeCallbacks(it) }
                if (isTyping) {
                    _typingPeers.value = _typingPeers.value + peerID
                    val runner = Runnable { _typingPeers.value = _typingPeers.value - peerID }
                    typingClearRunners[peerID] = runner
                    mainHandler.postDelayed(runner, 3000)
                } else {
                    _typingPeers.value = _typingPeers.value - peerID
                }
            }
        }
        _chatManager = mgr
        _groups.value = mgr.groupsList()
        mgr.start()
    }

    // -----------------------------------------------------------------------
    // 1:1 message helpers
    // -----------------------------------------------------------------------

    fun deleteMessage(messageID: String, conversationID: String) {
        messageStore.deleteMessage(messageID, conversationID)
        _messages.value = _messages.value.toMutableMap().also {
            it[conversationID] = messageStore.loadMessages(conversationID)
        }
    }

    fun sendMessage(toPeerID: String, body: String) {
        _chatManager?.sendMessage(toPeerID, body)
        _messages.value = _messages.value.toMutableMap().also {
            it[toPeerID] = messageStore.loadMessages(toPeerID)
        }
    }

    fun messagesFor(conversationID: String): List<StoredMessage> =
        _messages.value[conversationID] ?: messageStore.loadMessages(conversationID).also { msgs ->
            _messages.value = _messages.value.toMutableMap().also { it[conversationID] = msgs }
        }

    // -----------------------------------------------------------------------
    // Group helpers
    // -----------------------------------------------------------------------

    fun createGroup(name: String, memberPeerIDs: List<String>): GroupInfo {
        val group = _chatManager!!.createGroup(name, memberPeerIDs)
        _groups.value = _chatManager!!.groupsList()
        return group
    }

    fun sendGroupMessage(body: String, group: GroupInfo) {
        _chatManager?.sendGroupMessage(body, group)
        _messages.value = _messages.value.toMutableMap().also {
            it[group.conversationID] = messageStore.loadMessages(group.conversationID)
        }
    }

    fun leaveGroup(group: GroupInfo) {
        _chatManager?.leaveGroup(group)
        _groups.value = _chatManager?.groupsList() ?: emptyList()
    }

    // -----------------------------------------------------------------------
    // Settings
    // -----------------------------------------------------------------------

    fun changeUsername(newName: String) {
        if (newName.isBlank()) return
        identity.setUsername(newName)
        prefs.edit().putString("username", newName).apply()
        _username.value = newName
    }

    fun setTcpEnabled(enabled: Boolean) {
        prefs.edit().putBoolean("tcp_enabled", enabled).apply()
        _tcpEnabled.value = enabled
        if (!enabled) {
            _chatManager?.tcp?.stop()
        } else {
            _chatManager?.tcp?.start()
        }
    }

    fun setSocksProxy(proxy: String) {
        prefs.edit().putString("socks_proxy", proxy).apply()
        _socksProxy.value = proxy
        val parts = proxy.split(":")
        if (parts.size == 2) {
            _chatManager?.tcp?.setSocksProxy(parts[0], parts[1].toIntOrNull() ?: 9050)
        }
    }

    fun blockPeer(peerID: String) {
        val updated = (_blockedPeers.value + peerID).distinct()
        prefs.edit().putStringSet("blocked_peers", updated.toSet()).apply()
        _blockedPeers.value = updated
    }

    fun unblockPeer(peerID: String) {
        val updated = _blockedPeers.value.filter { it != peerID }
        prefs.edit().putStringSet("blocked_peers", updated.toSet()).apply()
        _blockedPeers.value = updated
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    override fun onCleared() {
        super.onCleared()
        _chatManager?.stop()
    }
}
