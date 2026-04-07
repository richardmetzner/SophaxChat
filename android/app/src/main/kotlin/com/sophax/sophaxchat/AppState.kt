package com.sophax.sophaxchat

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import java.util.concurrent.ConcurrentHashMap
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.sophax.sophaxchat.crypto.GroupInfo
import com.sophax.sophaxchat.crypto.IdentityManager
import com.sophax.sophaxchat.crypto.PreKeyManager
import com.sophax.sophaxchat.network.TorManager
import com.sophax.sophaxchat.network.TorState
import com.sophax.sophaxchat.notifications.NotificationHelper
import com.sophax.sophaxchat.protocol.KnownPeer
import com.sophax.sophaxchat.storage.AttachmentStore
import com.sophax.sophaxchat.storage.MessageDirection
import com.sophax.sophaxchat.storage.MessageStore
import com.sophax.sophaxchat.storage.StoredMessage
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class AppState(application: Application) : AndroidViewModel(application) {

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    private val prefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(getApplication())
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            getApplication(), "sophaxchat_prefs", masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    private val _isSetupComplete = MutableStateFlow(prefs.getBoolean("setup_complete", false))
    val isSetupComplete: StateFlow<Boolean> = _isSetupComplete.asStateFlow()

    // -----------------------------------------------------------------------
    // Core objects
    // -----------------------------------------------------------------------

    val identity     = IdentityManager(application)
    val messageStore = MessageStore(application)
    val torManager   = TorManager(application)

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

    private val _peerAvatarData = MutableStateFlow<Map<String, ByteArray>>(emptyMap())
    val peerAvatarData: StateFlow<Map<String, ByteArray>> = _peerAvatarData.asStateFlow()

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

    private val _verifiedPeers = MutableStateFlow<Map<String, String>>(
        run {
            val json = prefs.getString("verified_peers", null) ?: return@run emptyMap()
            try {
                Json.decodeFromString<Map<String, String>>(json)
            } catch (_: Exception) { emptyMap() }
        }
    )
    val verifiedPeers: StateFlow<Map<String, String>> = _verifiedPeers.asStateFlow()

    fun markPeerVerified(peerID: String, safetyNumber: String) {
        _verifiedPeers.value = _verifiedPeers.value + (peerID to safetyNumber)
        prefs.edit().putString("verified_peers",
            Json.encodeToString(_verifiedPeers.value)).apply()
    }

    fun isVerified(peerID: String, safetyNumber: String): Boolean =
        _verifiedPeers.value[peerID] == safetyNumber

    fun hasKeyChanged(peerID: String, safetyNumber: String): Boolean {
        val pinned = _verifiedPeers.value[peerID] ?: return false
        return pinned != safetyNumber
    }

    // Unread counts (in-memory; reset on markAsRead)
    private val _unreadCounts = MutableStateFlow<Map<String, Int>>(emptyMap())
    val unreadCounts: StateFlow<Map<String, Int>> = _unreadCounts.asStateFlow()

    fun markAsRead(conversationID: String) {
        messageStore.markAllRead(conversationID)
        _unreadCounts.value = _unreadCounts.value - conversationID
    }

    // Deep link confirmation
    data class PendingDeepLink(val peerID: String, val address: String, val host: String)

    private val _pendingDeepLink = MutableStateFlow<PendingDeepLink?>(null)
    val pendingDeepLink: StateFlow<PendingDeepLink?> = _pendingDeepLink.asStateFlow()

    fun handleIncomingLink(uri: Uri) {
        if (uri.scheme != "sophaxchat" || uri.host != "add") return
        val peerID = uri.getQueryParameter("id") ?: return
        val onion  = uri.getQueryParameter("onion") ?: return
        val onionRegex = Regex("^[a-z2-7]{56}\\.onion$")
        if (!onionRegex.matches(onion)) return
        val port    = uri.getQueryParameter("port") ?: "25519"
        val portInt = port.toIntOrNull()?.takeIf { it in 1..65535 } ?: 25519
        _pendingDeepLink.value = PendingDeepLink(peerID, "$onion:$portInt", onion)
    }

    fun confirmDeepLink() {
        val pending = _pendingDeepLink.value ?: return
        _pendingDeepLink.value = null
        try { _chatManager?.tcp?.connect(pending.address) } catch (_: Exception) {}
    }

    fun dismissDeepLink() {
        _pendingDeepLink.value = null
    }

    // Contact aliases (rename)
    private val _peerAliases = MutableStateFlow<Map<String, String>>(
        prefs.all.entries
            .filter { it.key.startsWith("alias_") }
            .associate { it.key.removePrefix("alias_") to (it.value as? String ?: "") }
    )
    val peerAliases: StateFlow<Map<String, String>> = _peerAliases.asStateFlow()

    fun renamePeer(peerID: String, alias: String) {
        _peerAliases.update { it + (peerID to alias) }
        prefs.edit().putString("alias_$peerID", alias).apply()
    }

    fun displayName(peerID: String, fallback: String): String =
        _peerAliases.value[peerID]?.takeIf { it.isNotBlank() } ?: fallback

    // Disappearing messages — per-conversation timer (ms, 0 = off)
    private val _disappearingTimers = MutableStateFlow<Map<String, Long>>(
        prefs.all.entries
            .filter { it.key.startsWith("disappear_") }
            .associate { it.key.removePrefix("disappear_") to (it.value as? Long ?: 0L) }
    )
    val disappearingTimers: StateFlow<Map<String, Long>> = _disappearingTimers.asStateFlow()

    fun setDisappearingTimer(conversationID: String, ms: Long) {
        _disappearingTimers.update { if (ms == 0L) it - conversationID else it + (conversationID to ms) }
        if (ms == 0L) prefs.edit().remove("disappear_$conversationID").apply()
        else prefs.edit().putLong("disappear_$conversationID", ms).apply()
    }

    // Typing indicators
    private val _typingPeers = MutableStateFlow<Set<String>>(emptySet())
    val typingPeers: StateFlow<Set<String>> = _typingPeers.asStateFlow()

    private val typingClearRunners = ConcurrentHashMap<String, Runnable>()
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
    // -----------------------------------------------------------------------
    // Linked Devices — multi-device sync
    // -----------------------------------------------------------------------

    private val _linkedDevices = MutableStateFlow<List<KnownPeer>>(emptyList())
    val linkedDevices: StateFlow<List<KnownPeer>> = _linkedDevices.asStateFlow()

    /** Returns JSON bytes encoding this device's PreKeyBundle, suitable for a QR code. */
    fun generateDeviceLinkQR(): ByteArray? = _chatManager?.generateDeviceLinkPayload()

    /** Process a scanned QR payload from another device and establish a link. */
    fun acceptDeviceLink(data: ByteArray) {
        _chatManager?.acceptDeviceLink(data)
        refreshLinkedDevices()
    }

    fun unlinkDevice(peer: KnownPeer) {
        _chatManager?.unlinkDevice(peer.id)
        refreshLinkedDevices()
    }

    private fun refreshLinkedDevices() {
        _linkedDevices.value = _chatManager?.linkedDevicesList() ?: emptyList()
    }

    // -----------------------------------------------------------------------
    // Duress PIN — silent decoy mode on coercion
    // -----------------------------------------------------------------------

    /** State: true while the app is showing the decoy (duress) UI. */
    private val _isDuressActive = MutableStateFlow(false)
    val isDuressActive: StateFlow<Boolean> = _isDuressActive.asStateFlow()

    /** Save a duress PIN (4–8 digits). Must differ from the real lock PIN. */
    fun setDuressPIN(pin: String) {
        require(pin.length in 4..8 && pin.all { it.isDigit() }) {
            "Duress PIN must be 4–8 digits."
        }
        prefs.edit().putString("duress_pin", pin).apply()
    }

    /** Remove the duress PIN (disables duress mode). */
    fun clearDuressPIN() {
        prefs.edit().remove("duress_pin").apply()
    }

    /** Returns true when a duress PIN has been configured. */
    fun hasDuressPIN(): Boolean = prefs.getString("duress_pin", null) != null

    /** Returns true when the supplied PIN matches the stored duress PIN. */
    fun verifyDuressPIN(pin: String): Boolean =
        prefs.getString("duress_pin", null)?.let { it == pin } ?: false

    /**
     * Activate duress mode:
     * – stops ChatManager (drops all in-memory state)
     * – sets isDuressActive = true so the UI shows an empty decoy
     * – does NOT wipe persisted data — the real app is intact after a real unlock
     */
    fun activateDuress() {
        _chatManager?.stop()
        _chatManager = null
        clearInMemoryState()
        _isDuressActive.value = true
        _isAppLocked.value = false   // unlock the lock screen; show decoy
    }

    /** Called when the user unlocks the real app after duress mode was active. */
    fun deactivateDuress() {
        _isDuressActive.value = false
        startIfReady()
    }

    /** Clears all in-memory collections — used by both lockApp() and activateDuress(). */
    private fun clearInMemoryState() {
        _peers.value   = emptyList()
        _messages.value = emptyMap()
        _groups.value  = emptyList()
        _unreadCounts.value = emptyMap()
        _typingPeers.value  = emptySet()
        _peerAvatarData.value = emptyMap()
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    private fun updateMessages(conversationID: String, msgs: List<StoredMessage>) {
        _messages.value = _messages.value + (conversationID to msgs)
    }

    private fun incrementUnread(conversationID: String) {
        _unreadCounts.value = _unreadCounts.value +
            (conversationID to (_unreadCounts.value[conversationID] ?: 0) + 1)
    }

    private fun parseSocksProxy(proxy: String, block: (host: String, port: Int) -> Unit) {
        val parts = proxy.split(":")
        if (parts.size == 2) block(parts[0], parts[1].toIntOrNull() ?: 9050)
    }

    // Reactions
    fun addReaction(conversationID: String, messageID: String, senderID: String, emoji: String?) {
        messageStore.addReaction(conversationID, messageID, senderID, emoji)
        updateMessages(conversationID, messageStore.loadMessages(conversationID))
    }

    fun sendReaction(toPeerID: String, messageID: String, emoji: String?, isGroup: Boolean = false, groupID: String? = null) {
        _chatManager?.sendReaction(toPeerID, messageID, emoji, isGroup, groupID)
        addReaction(if (isGroup && groupID != null) groupID else toPeerID, messageID, myPeerID, emoji)
    }

    // -----------------------------------------------------------------------
    // Notifications
    // -----------------------------------------------------------------------

    init {
        NotificationHelper.createChannel(getApplication())
        // Cleanup expired messages every 10s
        viewModelScope.launch {
            while (true) {
                delay(10_000)
                messageStore.deleteExpiredMessages()
                loadAllMessages()
            }
        }
        // Start embedded Tor immediately — proxy auto-configured on bootstrap
        torManager.start()
        observeTorState()
    }

    private fun observeTorState() {
        viewModelScope.launch {
            torManager.state.collect { torState ->
                if (torState is TorState.Ready && _socksProxy.value.isEmpty()) {
                    setSocksProxy(TorManager.SOCKS_PROXY)
                }
            }
        }
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
        val app = getApplication<Application>()
        val preKeys = PreKeyManager(identity, app)
        val mgr = ChatManager(app, identity, preKeys, messageStore)

        // Apply TCP settings
        if (_tcpEnabled.value) {
            val proxy = _socksProxy.value
            if (proxy.isNotEmpty()) {
                parseSocksProxy(proxy) { host, port -> mgr.tcp.setSocksProxy(host, port) }
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
                updateMessages(fromPeerID, (_messages.value[fromPeerID] ?: emptyList()) + message)
                incrementUnread(fromPeerID)
                val senderName = _peers.value.firstOrNull { it.id == fromPeerID }?.username
                    ?: fromPeerID.take(8)
                NotificationHelper.showMessage(
                    getApplication(),
                    title = senderName,
                    body = message.body,
                    conversationID = fromPeerID,
                    messageID = message.id
                )
            }
            override fun didReceiveGroupMessage(message: StoredMessage, group: GroupInfo) {
                updateMessages(
                    group.conversationID,
                    (_messages.value[group.conversationID] ?: emptyList()) + message
                )
                _groups.value = mgr.groupsList()
                incrementUnread(group.conversationID)
                val senderName = _peers.value.firstOrNull { it.id == message.peerID }?.username
                    ?: message.peerID.take(8)
                NotificationHelper.showMessage(
                    getApplication(),
                    title = group.name,
                    body = "$senderName: ${message.body}",
                    conversationID = group.conversationID,
                    messageID = message.id
                )
            }
            override fun messageDelivered(messageID: String, toPeerID: String) {
                // Status written to disk by store — reload to pick up updated status
                updateMessages(toPeerID, mgr.messages(toPeerID))
            }
            override fun didEncounterError(error: Exception) {
                _errorMessage.value = "Connection error. Please try again."
                if (BuildConfig.DEBUG) Log.e("AppState", "didEncounterError", error)
            }
            override fun didReceiveReaction(conversationID: String, messageID: String, emoji: String?, senderID: String) {
                addReaction(conversationID, messageID, senderID, emoji)
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
            override fun groupDeletedWithID(groupID: String) {
                _groups.value = _groups.value.filter { it.id != groupID }
                val convID = "group.$groupID"
                _messages.value = _messages.value - convID
                _unreadCounts.value = _unreadCounts.value - convID
            }
            override fun didReceiveAvatarData(data: ByteArray, fromPeerID: String) {
                _peerAvatarData.value = _peerAvatarData.value + (fromPeerID to data)
            }
        }
        _chatManager = mgr
        _groups.value = mgr.groupsList()
        _linkedDevices.value = mgr.linkedDevicesList()
        mgr.start()
    }

    // -----------------------------------------------------------------------
    // 1:1 message helpers
    // -----------------------------------------------------------------------

    fun safetyNumber(peerID: String): String? =
        _peers.value.firstOrNull { it.id == peerID }?.safetyNumber

    fun deleteMessage(messageID: String, conversationID: String) {
        messageStore.deleteMessage(messageID, conversationID)
        updateMessages(
            conversationID,
            (_messages.value[conversationID] ?: emptyList()).filter { it.id != messageID }
        )
    }

    fun sendMessage(toPeerID: String, body: String) {
        val expiresAt = _disappearingTimers.value[toPeerID]
            ?.takeIf { it > 0L }
            ?.let { System.currentTimeMillis() + it }
        _chatManager?.sendMessage(toPeerID, body, expiresAt)
        updateMessages(toPeerID, messageStore.loadMessages(toPeerID))
    }

    fun sendImage(toPeerID: String, imageBytes: ByteArray) {
        val cm = _chatManager ?: return
        val id = java.util.UUID.randomUUID().toString()
        try {
            cm.attachmentStore.save(imageBytes, id)
        } catch (_: Exception) { return }
        val stored = StoredMessage(
            id = id, peerID = toPeerID,
            direction = MessageDirection.sent.name,
            body = "[image]",
            attachmentMimeType = "image/jpeg"
        )
        messageStore.store(stored)
        updateMessages(toPeerID, messageStore.loadMessages(toPeerID))
        cm.sendMessage(toPeerID, "[image:$id]")
    }

    val myTCPAddress: String get() = _chatManager?.myTCPAddress ?: ""

    val myContactUrl: String get() {
        val peerID = identity.publicIdentity.peerID
        val onion = _chatManager?.myTCPAddress ?: return ""
        val port = prefs.getString("tcp_port", "25519") ?: "25519"
        return "sophaxchat://add?id=$peerID&onion=$onion&port=$port"
    }

    fun messagesFor(conversationID: String): List<StoredMessage> =
        _messages.value[conversationID] ?: messageStore.loadMessages(conversationID).also { msgs ->
            updateMessages(conversationID, msgs)
        }

    // -----------------------------------------------------------------------
    // Group helpers
    // -----------------------------------------------------------------------

    fun createGroup(name: String, memberPeerIDs: List<String>): GroupInfo? {
        val mgr = _chatManager ?: return null
        val group = mgr.createGroup(name, memberPeerIDs)
        _groups.value = mgr.groupsList()
        return group
    }

    fun sendGroupMessage(body: String, group: GroupInfo) {
        _chatManager?.sendGroupMessage(body, group)
        updateMessages(group.conversationID, messageStore.loadMessages(group.conversationID))
    }

    fun leaveGroup(group: GroupInfo) {
        _chatManager?.leaveGroup(group)
        _groups.value = _chatManager?.groupsList() ?: emptyList()
    }

    fun deleteGroup(group: GroupInfo) {
        _chatManager?.deleteGroup(group)
        _groups.value = _chatManager?.groupsList() ?: emptyList()
        _messages.value = _messages.value - group.conversationID
        _unreadCounts.value = _unreadCounts.value - group.conversationID
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
        parseSocksProxy(proxy) { host, port -> _chatManager?.tcp?.setSocksProxy(host, port) }
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
    // Backup / Restore
    // -----------------------------------------------------------------------

    fun exportBackup(passphrase: String, destUri: Uri): String? = try {
        val conversationIDs = messageStore.allConversationIDs()
        val allMessages = conversationIDs.associateWith { messageStore.loadMessages(it) }
        val peers = _chatManager?.knownPeersList()?.map { mapOf("id" to it.id, "username" to it.username) } ?: emptyList()
        val backupMap = mapOf(
            "version" to "1",
            "username" to (_username.value),
            "peers" to Json.encodeToString(peers),
            "conversationIDs" to Json.encodeToString(conversationIDs),
            "messages" to Json.encodeToString(allMessages)
        )
        val jsonPayload = Json.encodeToString(backupMap).toByteArray()
        val encrypted = pbkdf2Encrypt(passphrase, jsonPayload)
        getApplication<Application>().contentResolver.openOutputStream(destUri)?.use { it.write(encrypted) }
        null
    } catch (e: Exception) { "Export failed: ${e.message}" }

    fun importBackup(passphrase: String, srcUri: Uri): String? = try {
        val bytes = getApplication<Application>().contentResolver.openInputStream(srcUri)
            ?.use { it.readBytes() } ?: return "Could not read file."
        val jsonPayload = try { pbkdf2Decrypt(passphrase, bytes) }
            catch (_: javax.crypto.BadPaddingException) { return "Wrong passphrase." }
        val backupMap = Json.decodeFromString<Map<String, String>>(String(jsonPayload))
        val conversationIDs = Json.decodeFromString<List<String>>(backupMap["conversationIDs"] ?: "[]")
        val allMessages = Json.decodeFromString<Map<String, List<StoredMessage>>>(backupMap["messages"] ?: "{}")
        conversationIDs.forEach { convID ->
            allMessages[convID]?.forEach { messageStore.store(it) }
        }
        loadAllMessages()
        null
    } catch (_: javax.crypto.BadPaddingException) { "Wrong passphrase." }
      catch (e: Exception) { "Restore failed: ${e.message}" }

    private fun loadAllMessages() {
        val convIDs = messageStore.allConversationIDs()
        _messages.value = convIDs.associateWith { messageStore.loadMessages(it) }
    }

    private fun pbkdf2Encrypt(passphrase: String, data: ByteArray): ByteArray {
        val salt = java.security.SecureRandom().generateSeed(16)
        val key = deriveKey(passphrase, salt)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        val ct = cipher.doFinal(data)
        return salt + iv + ct
    }

    private fun pbkdf2Decrypt(passphrase: String, data: ByteArray): ByteArray {
        val salt = data.copyOfRange(0, 16)
        val iv   = data.copyOfRange(16, 28)
        val ct   = data.copyOfRange(28, data.size)
        val key  = deriveKey(passphrase, salt)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.DECRYPT_MODE, key, javax.crypto.spec.GCMParameterSpec(128, iv))
        return cipher.doFinal(ct)
    }

    private fun deriveKey(passphrase: String, salt: ByteArray): javax.crypto.SecretKey {
        val factory = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val spec = javax.crypto.spec.PBEKeySpec(passphrase.toCharArray(), salt, 100_000, 256)
        val tmp = factory.generateSecret(spec)
        return javax.crypto.spec.SecretKeySpec(tmp.encoded, "AES")
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    override fun onCleared() {
        super.onCleared()
        mainHandler.removeCallbacksAndMessages(null)
        _chatManager?.stop()
    }
}
