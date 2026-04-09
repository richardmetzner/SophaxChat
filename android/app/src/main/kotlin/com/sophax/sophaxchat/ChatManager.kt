package com.sophax.sophaxchat

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.google.crypto.tink.subtle.ChaCha20Poly1305
import com.sophax.sophaxchat.crypto.DHKeyPair
import com.sophax.sophaxchat.crypto.DoubleRatchet
import com.sophax.sophaxchat.crypto.GroupInfo
import com.sophax.sophaxchat.crypto.GroupInvitePayload
import com.sophax.sophaxchat.crypto.IdentityManager
import com.sophax.sophaxchat.crypto.PreKeyManager
import com.sophax.sophaxchat.crypto.SenderKeyState
import com.sophax.sophaxchat.crypto.X3DH
import com.sophax.sophaxchat.crypto.PreKeyBundleLocal
import com.sophax.sophaxchat.crypto.toHex
import com.sophax.sophaxchat.network.DHTBootstrap
import com.sophax.sophaxchat.network.DHTContact
import com.sophax.sophaxchat.network.DHTEngine
import com.sophax.sophaxchat.network.DHTStorage
import com.sophax.sophaxchat.network.LanDiscovery
import com.sophax.sophaxchat.network.LanDiscoveryListener
import com.sophax.sophaxchat.network.NearbyManager
import com.sophax.sophaxchat.network.NearbyManagerListener
import com.sophax.sophaxchat.network.TcpTransport
import com.sophax.sophaxchat.network.TcpTransportListener
import com.sophax.sophaxchat.network.WifiDirectManager
import com.sophax.sophaxchat.protocol.*
import com.sophax.sophaxchat.storage.AttachmentStore
import com.sophax.sophaxchat.storage.MessageDirection
import com.sophax.sophaxchat.storage.MessageStatus
import com.sophax.sophaxchat.storage.MessageStore
import com.sophax.sophaxchat.storage.StoredMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import java.security.SecureRandom
import java.util.Date
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

// ---------------------------------------------------------------------------
// Delegate
// ---------------------------------------------------------------------------

interface ChatManagerDelegate {
    fun didDiscoverPeer(peer: KnownPeer)
    fun peerDidDisconnect(peerID: String)
    fun didReceiveMessage(message: StoredMessage, fromPeerID: String)
    fun didReceiveGroupMessage(message: StoredMessage, group: GroupInfo)
    fun messageDelivered(messageID: String, toPeerID: String)
    fun didEncounterError(error: Exception)
    fun didUpdateTypingState(peerID: String, isTyping: Boolean)
    fun didReceiveReaction(conversationID: String, messageID: String, emoji: String?, senderID: String = conversationID)
    /** The group creator dissolved the group; the local client must drop it. */
    fun groupDeletedWithID(groupID: String)
    /** A group message carried avatar data for a peer not yet in the avatar cache. */
    fun didReceiveAvatarData(data: ByteArray, fromPeerID: String)
    /** A trusted peer requested a remote account wipe. */
    fun didReceiveRemoteWipeRequest()
}

// ---------------------------------------------------------------------------
// ChatManager — coordinates crypto, transport, and storage
// Port of iOS ChatManager.swift (Phase 2 scope: 1-to-1 messaging + relay)
// ---------------------------------------------------------------------------

/** Returns true when Google Play Services with Nearby Connections is available at runtime. */
private fun isNearbyAvailable(context: Context): Boolean = runCatching {
    context.packageManager.getPackageInfo("com.google.android.gms", 0)
    Class.forName("com.google.android.gms.nearby.Nearby")
    true
}.getOrDefault(false)

class ChatManager(
    private val context: Context,
    val identity: IdentityManager,
    private val preKeys: PreKeyManager,
    private val messageStore: MessageStore
) {
    var delegate: ChatManagerDelegate? = null
    var myTCPAddress: String? = null     // "host:port" advertised to peers

    private val json = Json { ignoreUnknownKeys = true }

    // Active Double Ratchet sessions — peerID → session
    private val sessions     = ConcurrentHashMap<String, DoubleRatchet>()
    private val sessionLock  = Any()

    // Known peer identities (verified)
    private val knownPeers   = ConcurrentHashMap<String, KnownPeer>()

    // -----------------------------------------------------------------------
    // DHT engine (Kademlia peer discovery over Tor)
    // -----------------------------------------------------------------------

    private var dhtEngine: DHTEngine? = null
    private val dhtStorage by lazy { DHTStorage(context) }
    private val dhtScope   = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    /** address → queued DHT messages waiting for TCP connection. */
    private val pendingDHTMessages = ConcurrentHashMap<String, ArrayDeque<WireMessage>>()
    /** senderID → (windowStart, count) for 30 DHT req/min rate limit. */
    private val dhtRateLimiters = ConcurrentHashMap<String, Pair<Long, Int>>()
    private var lastDHTPublish: Long = 0L

    // -----------------------------------------------------------------------
    // Linked devices — peerIDs of other devices belonging to the same user.
    // Persisted in EncryptedSharedPreferences as a JSON string list.
    // -----------------------------------------------------------------------
    val linkedDeviceIDs = ConcurrentHashMap<String, Boolean>()
    private val LINKED_DEVICES_KEY = "linked_device_ids"

    private fun saveLinkedDevices() {
        val ids = linkedDeviceIDs.keys().toList()
        groupPrefs.edit().putString(LINKED_DEVICES_KEY, json.encodeToString(ids)).apply()
    }

    private fun loadLinkedDevices() {
        val raw = groupPrefs.getString(LINKED_DEVICES_KEY, null) ?: return
        val ids = try { json.decodeFromString<List<String>>(raw) } catch (e: Exception) { return }
        ids.forEach { linkedDeviceIDs[it] = true }
    }

    /** Unlink a device — it will no longer receive message copies. */
    fun unlinkDevice(peerID: String) {
        linkedDeviceIDs.remove(peerID)
        saveLinkedDevices()
    }

    /** Returns the list of KnownPeer objects for linked devices. */
    fun linkedDevicesList(): List<KnownPeer> =
        linkedDeviceIDs.keys().toList().mapNotNull { knownPeers[it] }

    /**
     * Generate a JSON payload (base64) that encodes this device's PreKeyBundle.
     * Encode as a QR code on screen; the other device scans it.
     */
    fun generateDeviceLinkPayload(): ByteArray {
        val bundle  = preKeys.generateBundle(myTCPAddress)
        val msg     = DeviceLinkRequestMessage(
            deviceLabel = android.os.Build.MODEL,
            bundle      = bundle
        )
        return json.encodeToString(msg).toByteArray()
    }

    /**
     * Accept a device link from scanned QR data.
     * Parses the DeviceLinkRequestMessage, stores the bundle, registers as linked,
     * then sends a reciprocal deviceLinkRequest so the other device gets our bundle too.
     */
    fun acceptDeviceLink(data: ByteArray) {
        val msg = try { json.decodeFromString<DeviceLinkRequestMessage>(String(data)) }
                  catch (e: Exception) { return }
        val bundle = msg.bundle
        val peerID = bundle.peerID

        peerBundles[peerID] = bundle

        val peer = KnownPeer(
            id = peerID, username = msg.deviceLabel,
            signingKeyPublic = bundle.signingKeyPublic,
            dhKeyPublic      = bundle.dhIdentityKeyPublic,
            safetyNumber     = IdentityManager.safetyNumber(
                identity.publicIdentity.signingKeyPublic, bundle.signingKeyPublic,
                identity.publicIdentity.dhKeyPublic, bundle.dhIdentityKeyPublic
            ),
            lastSeen = Date(), isOnline = false
        )
        knownPeers[peerID] = peer
        linkedDeviceIDs[peerID] = true
        saveLinkedDevices()
        delegate?.didDiscoverPeer(peer)

        // Send reciprocal link request
        val myMsg  = DeviceLinkRequestMessage(
            deviceLabel = android.os.Build.MODEL,
            bundle      = preKeys.generateBundle(myTCPAddress)
        )
        val wire = builder().build(WireMessageType.deviceLinkRequest.name, myMsg)
        sendOrRoute(wire, peerID)
    }

    // -----------------------------------------------------------------------
    // Store-and-forward queue — holds sealed messages for offline peers.
    // Key = targetPeerID. Max 50 messages/peer, TTL 48h.
    // -----------------------------------------------------------------------
    private val storeAndForwardQueue = ConcurrentHashMap<String, MutableList<StoreAndForwardRequest>>()
    private val SAF_MAX_PER_PEER = 50
    private val SAF_TTL_MS = 48L * 60 * 60 * 1000  // 48 hours in ms

    // -----------------------------------------------------------------------
    // Dead drops — sealed mesh-flood messages for offline recipients.
    // seenDeadDropIDs: id → received-at epoch ms (for dedup + expiry).
    // -----------------------------------------------------------------------
    private val deadDrops          = mutableListOf<DeadDropEnvelope>()
    private val deadDropLock       = Any()
    private val seenDeadDropIDs    = ConcurrentHashMap<String, Long>()

    // -----------------------------------------------------------------------
    // Remote Wipe — trusted peers can request account wipe.
    // Persisted in groupPrefs under "trusted_wipe_peers".
    // -----------------------------------------------------------------------
    private val trustedWipePeers: MutableSet<String> = loadTrustedWipePeers()
    private val seenWipeRequestIDs = ConcurrentHashMap<String, Boolean>()

    // Received peer bundles (for initiating X3DH)
    private val peerBundles  = ConcurrentHashMap<String, PreKeyBundle>()

    // Avatar cache: peerID → JPEG bytes (≤8 KB). Populated from piggybacked group messages.
    val peerAvatarData = ConcurrentHashMap<String, ByteArray>()

    // Messages queued while waiting for a peer's bundle: Pair(body, messageID)
    private val pendingQueue = ConcurrentHashMap<String, ArrayDeque<Pair<String, String>>>()

    // Nearby endpoint ID → peerID (learned from Hello)
    private val endpointToPeerID = ConcurrentHashMap<String, String>()
    private val peerIDToEndpoint = ConcurrentHashMap<String, String>()

    // TCP connection: peerID → address (already tracked by TcpTransport)
    private val tcpPeerIDs = ConcurrentHashMap<String, Boolean>()
    /** address → peerID, populated when TCP handshake completes. */
    private val tcpAddressToPeerID = ConcurrentHashMap<String, String>()

    // Tracks when each DR session was established (epoch ms).
    // Used to reject replayed or duplicate initiateSession messages.
    private val sessionCreatedAt = ConcurrentHashMap<String, Long>()

    // -----------------------------------------------------------------------
    // Group state (EncryptedSharedPreferences)
    // -----------------------------------------------------------------------

    private val groupPrefs by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context, "sophaxchat_groups", masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    private fun loadGroups(): List<GroupInfo> {
        val raw = groupPrefs.getString("groups_json", null) ?: return emptyList()
        return try { json.decodeFromString(raw) } catch (e: Exception) { emptyList() }
    }

    private fun saveGroups(groups: List<GroupInfo>) {
        groupPrefs.edit().putString("groups_json", json.encodeToString(groups)).apply()
    }

    private fun loadSenderKey(groupID: String, peerID: String): SenderKeyState? {
        val raw = groupPrefs.getString("skey_${groupID}_${peerID}", null) ?: return null
        return try { json.decodeFromString(raw) } catch (e: Exception) { null }
    }

    private fun saveSenderKey(groupID: String, peerID: String, state: SenderKeyState) {
        groupPrefs.edit()
            .putString("skey_${groupID}_${peerID}", json.encodeToString(state))
            .apply()
    }

    private fun deleteSenderKeys(groupID: String) {
        val editor = groupPrefs.edit()
        groupPrefs.all.keys
            .filter { it.startsWith("skey_${groupID}_") }
            .forEach { editor.remove(it) }
        editor.apply()
    }

    /** In-memory group list, kept in sync with prefs. */
    private val groups = ConcurrentHashMap<String, GroupInfo>().also { map ->
        loadGroups().forEach { map[it.id] = it }
    }

    fun groupsList(): List<GroupInfo> = groups.values.toList()

    val attachmentStore = AttachmentStore(context)

    // -----------------------------------------------------------------------
    // Transports
    // -----------------------------------------------------------------------

    // Nearby Connections (GMS) — null on GrapheneOS / LineageOS without GMS
    val nearby: NearbyManager? = if (isNearbyAvailable(context))
        NearbyManager(context).also { it.listener = nearbyListener } else null

    // Wi-Fi Direct — used when GMS is absent; pure Android SDK, no external dependency
    private val wifiDirect: WifiDirectManager? = if (nearby == null)
        WifiDirectManager(context).also { it.onPeerFound = { addr -> tcp.connect(addr) } } else null

    val tcp = TcpTransport(helloProvider = { buildHello() }).also { it.listener = tcpListener }

    // mDNS discovery — auto-connects to Android and iOS peers on the same WiFi
    private val lan = LanDiscovery(context).also {
        it.listener = object : LanDiscoveryListener {
            override fun onLanPeerFound(address: String) {
                tcp.connect(address)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Start / Stop
    // -----------------------------------------------------------------------

    fun start() {
        preKeys.rotateIfNeeded()
        loadLinkedDevices()
        val myPeerID = identity.publicIdentity.peerID
        val displayName = "sx-${myPeerID.take(12)}"
        nearby?.start(displayName) ?: wifiDirect?.start(myPeerID)
        tcp.start()
        lan.start(myPeerID)
    }

    fun stop() {
        nearby?.stop() ?: wifiDirect?.stop()
        tcp.stop()
        lan.stop()
        stopDHT()
    }

    // -----------------------------------------------------------------------
    // DHT lifecycle
    // -----------------------------------------------------------------------

    fun startDHT() {
        val wireBuilder = WireMessageBuilder(identity)
        val engine = DHTEngine(
            identity    = identity,
            wireBuilder = wireBuilder,
            scope       = dhtScope,
            send        = { msg, contact -> sendDHTMessage(msg, contact) }
        )
        dhtEngine = engine

        // Bootstrap priority: (1) persisted k-buckets, (2) knownPeers with tcpAddress,
        // (3) hardcoded DHTBootstrap.nodes
        val persisted = dhtStorage.load()
        val fromPeers = knownPeers.values.mapNotNull { peer ->
            val addr = peer.tcpAddress ?: return@mapNotNull null
            val host = addr.substringBeforeLast(':')
            if (!host.endsWith(".onion")) return@mapNotNull null
            val port = addr.substringAfterLast(':').toIntOrNull() ?: return@mapNotNull null
            DHTContact(
                nodeID       = peer.id.padEnd(64, '0'),
                onionAddress = host,
                port         = port
            )
        }
        val bootstrapContacts = (persisted + fromPeers + DHTBootstrap.nodes).distinctBy { it.nodeID }
        engine.start(bootstrapContacts)

        // Publish our PreKeyBundle immediately after bootstrap so peers can find us,
        // then re-publish every 24 hours.
        dhtScope.launch {
            publishDHTBundle(engine)
            while (true) {
                kotlinx.coroutines.delay(DHTEngine.PUBLISH_INTERVAL)
                publishDHTBundle(engine)
            }
        }

        // Schedule k-bucket snapshot every 30 minutes
        dhtScope.launch {
            while (true) {
                kotlinx.coroutines.delay(30L * 60 * 1000)
                dhtEngine?.let { eng ->
                    val snapshot = eng.table.snapshot()
                    dhtStorage.save(snapshot)
                }
            }
        }
    }

    private suspend fun publishDHTBundle(engine: DHTEngine) {
        val bundle = runCatching { preKeys.generateBundle(myTCPAddress) }.getOrNull() ?: return
        engine.publishSelf(bundle)
    }

    private fun stopDHT() {
        dhtEngine?.stop()
        dhtEngine = null
        dhtScope.cancel()
    }

    private suspend fun sendDHTMessage(msg: WireMessage, contact: DHTContact) {
        val address = "${contact.onionAddress}:${contact.port}"
        val peerID  = tcpAddressToPeerID[address]
        if (peerID != null && tcp.isConnected(peerID)) {
            runCatching { tcp.send(msg, peerID) }
        } else {
            pendingDHTMessages.getOrPut(address) { ArrayDeque() }.addLast(msg)
            tcp.connect(address)
        }
    }

    /** Lookup a peer by their 16-char peerID via DHT.
     *  Returns a KnownPeer populated from the discovered PreKeyBundle, or null. */
    suspend fun lookupPeer(peerID: String): KnownPeer? {
        val engine = dhtEngine ?: return null
        val (_, bundle) = engine.lookup(peerID) ?: return null
        val existing = knownPeers[bundle.peerID]
        if (existing != null) return existing
        val peer = KnownPeer(
            id               = bundle.peerID,
            username         = bundle.username,
            signingKeyPublic = bundle.signingKeyPublic,
            dhKeyPublic      = bundle.dhIdentityKeyPublic,
            safetyNumber     = bundle.peerID,
            tcpAddress       = bundle.tcpAddress
        )
        knownPeers[peer.id] = peer
        return peer
    }

    // -----------------------------------------------------------------------
    // Send message
    // -----------------------------------------------------------------------

    fun sendTyping(toPeerID: String) {
        val wire = builder().build(WireMessageType.typing.name, TypingMessage(isTyping = true))
        sendOrRoute(wire, toPeerID)
    }

    fun sendMessage(toPeerID: String, body: String, expiresAt: Long? = null) {
        val messageID = UUID.randomUUID().toString()

        val stored = StoredMessage(
            id = messageID, peerID = toPeerID,
            direction = MessageDirection.sent.name, body = body,
            status = MessageStatus.sending.name, expiresAt = expiresAt
        )
        messageStore.store(stored)

        val wire = buildOutboundWire(toPeerID, body, messageID, expiresAt) ?: return
        sendOrRoute(wire, toPeerID)
    }

    // -----------------------------------------------------------------------
    // Build outbound wire (X3DH or DR encrypt)
    // -----------------------------------------------------------------------

    private fun buildOutboundWire(peerID: String, body: String, messageID: String, expiresAt: Long? = null): WireMessage? {
        val content = MessageContent(body = body, timestamp = Date(),
            expiresAt = expiresAt?.let { Date(it) })
        val contentBytes = json.encodeToString(content).toByteArray()

        // Case 1: existing DR session
        // encrypt() mutates DR state — hold the lock for the entire operation.
        synchronized(sessionLock) { sessions[peerID] }?.let { dr ->
            return try {
                val ratchetMessage = synchronized(sessionLock) { dr.encrypt(contentBytes) }.toWire()
                val payload = ChatMessagePayload(ratchetMessage = ratchetMessage, messageID = messageID)
                builder().build(WireMessageType.message.name, payload)
            } catch (e: Exception) { delegate?.didEncounterError(e); null }
        }

        // Case 2: initiate X3DH (have bundle, no session)
        val bundle = peerBundles[peerID] ?: run {
            // No bundle yet — queue message body until peer's bundle arrives
            pendingQueue.getOrPut(peerID) { ArrayDeque() }.add(Pair(body, messageID))
            return null
        }

        return try {
            val local = PreKeyBundleLocal(
                dhIdentityKeyPublic  = bundle.dhIdentityKeyPublic,
                signedPreKeyPublic   = bundle.signedPreKeyPublic,
                oneTimePreKeyPublic  = bundle.oneTimePreKeyPublic,
                oneTimePreKeyId      = bundle.oneTimePreKeyId?.toUInt()
            )
            val x3dhResult = X3DH.initiateSender(identity.dhIdentityKeyPair, local)
            val dr = DoubleRatchet.initAsInitiator(x3dhResult.sharedSecret, bundle.signedPreKeyPublic)
            synchronized(sessionLock) { sessions[peerID] = dr }

            val initMsg = InitiateSessionMessage(
                senderBundle         = preKeys.generateBundle(myTCPAddress),
                ephemeralPublicKey   = x3dhResult.ephemeralPublicKey,
                usedSignedPreKeyId   = bundle.signedPreKeyId,
                usedOneTimePreKeyId  = x3dhResult.usedOneTimePreKeyId?.toLong(),
                initialMessage       = dr.encrypt(contentBytes).toWire()
            )
            builder().build(WireMessageType.initiateSession.name, initMsg)
        } catch (e: Exception) { delegate?.didEncounterError(e); null }
    }

    // -----------------------------------------------------------------------
    // Route message: TCP → Nearby → Relay
    // -----------------------------------------------------------------------

    private fun sendOrRoute(wire: WireMessage, toPeerID: String) {
        // Build relay envelope lazily (only if needed)
        fun relayWire(): WireMessage {
            val relay = RelayEnvelope(
                id = UUID.randomUUID().toString(),
                targetPeerID = toPeerID,
                originPeerID = identity.publicIdentity.peerID,
                ttl = RelayEnvelope.MAX_TTL,
                hopCount = 0,
                message = wire
            )
            return builder().build(WireMessageType.relay.name, relay)
        }

        when {
            // 1. TCP direct (highest priority — works on GMS and non-GMS alike)
            tcp.isConnected(toPeerID) ->
                tcp.send(wire, toPeerID)

            // 2. Nearby direct (GMS devices only)
            nearby != null && peerIDToEndpoint[toPeerID] != null ->
                nearby.send(wire, peerIDToEndpoint[toPeerID] ?: return)

            // 3a. Relay via Nearby mesh (GMS devices)
            nearby != null && nearby.connectedEndpointIDs().isNotEmpty() ->
                nearby.broadcast(relayWire())

            // 3b. Relay via TCP connections (non-GMS: WifiDirect / mDNS peers)
            tcp.connectedPeerIDs().isNotEmpty() ->
                tcp.broadcast(relayWire(), excluding = null)
        }
        // If no path available, message is silently dropped until reconnection.
        // (Persistent offline queue is a future enhancement.)
    }

    // -----------------------------------------------------------------------
    // Group messaging
    // -----------------------------------------------------------------------

    fun createGroup(name: String, memberPeerIDs: List<String>): GroupInfo {
        val myID = identity.publicIdentity.peerID
        val allMembers = (memberPeerIDs + myID).distinct()
        val group = GroupInfo(name = name, memberIDs = allMembers, creatorID = myID)

        // Generate my sender chain key
        val chainKey = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val myState = SenderKeyState(chainKey = chainKey)
        saveSenderKey(group.id, myID, myState)

        // Persist group
        groups[group.id] = group
        saveGroups(groups.values.toList())

        // Send invite to each member via DR-encrypted .message
        val invite = GroupInvitePayload(
            groupID = group.id,
            groupName = group.name,
            memberIDs = allMembers,
            creatorID = myID,
            senderChainKey = chainKey,
            senderIteration = 0L
        )
        val inviteBytes = json.encodeToString(invite).toByteArray()
        memberPeerIDs.forEach { peerID ->
            val wire = buildOutboundGroupInvite(peerID, inviteBytes) ?: return@forEach
            sendOrRoute(wire, peerID)
        }
        return group
    }

    fun sendGroupMessage(body: String, group: GroupInfo) {
        val myID = identity.publicIdentity.peerID
        val state = loadSenderKey(group.id, myID) ?: run {
            val fresh = SenderKeyState(ByteArray(32).also { SecureRandom().nextBytes(it) })
            saveSenderKey(group.id, myID, fresh)
            fresh
        }

        val (messageKey, nextState) = state.ratchet()
        saveSenderKey(group.id, myID, nextState)

        val ciphertext = chachaPoly(messageKey).encrypt(body.toByteArray(), group.id.toByteArray())
        val messageID  = UUID.randomUUID().toString()

        val gwm = GroupWireMessage(
            groupID = group.id,
            messageID = messageID,
            senderPeerID = myID,
            senderUsername = identity.username,
            timestamp = Date(),
            ciphertext = ciphertext,
            senderKeyIteration = state.iteration
        )

        // Store locally
        val stored = StoredMessage(
            id = messageID, peerID = group.conversationID,
            direction = MessageDirection.sent.name,
            body = body, status = MessageStatus.delivered.name
        )
        messageStore.store(stored)

        broadcastToGroup(group, gwm)
    }

    fun sendReaction(toPeerID: String, messageID: String, emoji: String?, isGroup: Boolean, groupID: String?) {
        if (isGroup && groupID != null) {
            val r = GroupReactionMessage(groupID = groupID, targetMessageID = messageID, emoji = emoji)
            val wire = builder().build(WireMessageType.groupReaction.name, r)
            groups[groupID]?.memberIDs
                ?.filter { it != identity.publicIdentity.peerID }
                ?.forEach { sendOrRoute(wire, it) }
        } else {
            val r = ReactionMessage(targetMessageID = messageID, emoji = emoji)
            val wire = buildReactionWire(toPeerID, r) ?: return
            sendOrRoute(wire, toPeerID)
        }
    }

    private fun buildReactionWire(peerID: String, reaction: ReactionMessage): WireMessage? {
        val bytes = json.encodeToString(reaction).toByteArray()
        synchronized(sessionLock) { sessions[peerID] }?.let { dr ->
            return try {
                val ratchetMessage = synchronized(sessionLock) { dr.encrypt(bytes) }.toWire()
                val payload = ChatMessagePayload(
                    ratchetMessage = ratchetMessage,
                    messageID = UUID.randomUUID().toString()
                )
                builder().build(WireMessageType.reaction.name, payload)
            } catch (e: Exception) { delegate?.didEncounterError(e); null }
        }
        return null
    }

    /** Creator-only: dissolve the group for all members. */
    fun deleteGroup(group: GroupInfo) {
        val myID = identity.publicIdentity.peerID
        if (group.creatorID != myID) return
        val msg  = GroupDeletedMessage(group.id, myID)
        val wire = builder().build(WireMessageType.groupDeleted.name, msg)
        group.memberIDs.filter { it != myID }.forEach { peerID -> sendOrRoute(wire, peerID) }
        groups.remove(group.id)
        deleteSenderKeys(group.id)
        messageStore.deleteConversation(group.conversationID)
        saveGroups(groups.values.toList())
    }

    fun leaveGroup(group: GroupInfo) {
        val myID = identity.publicIdentity.peerID
        val remaining = group.memberIDs.filter { it != myID }
        val left = GroupMemberLeftMessage(group.id, myID, remaining)
        val wire = builder().build(WireMessageType.groupMemberLeft.name, left)
        remaining.forEach { peerID -> sendOrRoute(wire, peerID) }
        groups.remove(group.id)
        deleteSenderKeys(group.id)
        saveGroups(groups.values.toList())
    }

    private fun handleGroupMessage(message: WireMessage) {
        val gwm = try { json.decodeFromString<GroupWireMessage>(String(message.payload)) }
                  catch (e: Exception) { return }

        val group = groups[gwm.groupID] ?: return
        val senderID = gwm.senderPeerID

        // Cache piggybacked avatar (≤8 KB guard)
        gwm.senderAvatarData?.takeIf { it.size <= 8_192 && !peerAvatarData.containsKey(senderID) }?.let {
            peerAvatarData[senderID] = it
            delegate?.didReceiveAvatarData(it, senderID)
        }

        val targetIteration = gwm.senderKeyIteration ?: 0L
        val state = loadSenderKey(gwm.groupID, senderID) ?: return

        val (messageKey, nextState) = try { state.advanceTo(targetIteration) }
                                       catch (e: Exception) { return }
        saveSenderKey(gwm.groupID, senderID, nextState)

        val plaintext = try {
            chachaPoly(messageKey).decrypt(gwm.ciphertext, group.id.toByteArray())
        } catch (e: Exception) { return }

        val body = String(plaintext)
        val stored = StoredMessage(
            id = gwm.messageID, peerID = group.conversationID,
            direction = MessageDirection.received.name,
            body = body, status = MessageStatus.delivered.name
        )
        messageStore.store(stored)
        delegate?.didReceiveGroupMessage(stored, group)
    }

    private fun handleGroupDeleted(message: WireMessage) {
        val msg = try { json.decodeFromString<GroupDeletedMessage>(String(message.payload)) }
                  catch (e: Exception) { return }
        val group = groups[msg.groupID] ?: return
        // Only accept from the known group creator
        if (message.senderID != group.creatorID) return
        groups.remove(msg.groupID)
        deleteSenderKeys(msg.groupID)
        messageStore.deleteConversation(group.conversationID)
        saveGroups(groups.values.toList())
        delegate?.groupDeletedWithID(msg.groupID)
    }

    private fun handleGroupMemberLeft(message: WireMessage) {
        val msg = try { json.decodeFromString<GroupMemberLeftMessage>(String(message.payload)) }
                  catch (e: Exception) { return }

        val group = groups[msg.groupID] ?: return
        val updated = group.copy(memberIDs = msg.remainingMemberIDs)
        groups[msg.groupID] = updated
        saveGroups(groups.values.toList())
        deleteSenderKeys("${msg.groupID}_${msg.leavingPeerID}")
    }

    private fun buildOutboundGroupInvite(peerID: String, inviteBytes: ByteArray): WireMessage? {
        // Wrap the invite in a MessageContent with type="groupInvite" and send as DR-encrypted .message
        val content = MessageContent(
            body = "",
            type = "groupInvite",
            groupInviteData = inviteBytes,
            timestamp = Date()
        )
        val contentBytes = json.encodeToString(content).toByteArray()
        return synchronized(sessionLock) { sessions[peerID] }?.let { dr ->
            try {
                val ratchetMessage = synchronized(sessionLock) { dr.encrypt(contentBytes) }.toWire()
                val payload = ChatMessagePayload(
                    ratchetMessage = ratchetMessage,
                    messageID = UUID.randomUUID().toString()
                )
                builder().build(WireMessageType.message.name, payload)
            } catch (e: Exception) { null }
        }
    }

    private fun broadcastToGroup(group: GroupInfo, gwm: GroupWireMessage) {
        val wire = builder().build(WireMessageType.groupMessage.name, gwm)
        val myID = identity.publicIdentity.peerID
        group.memberIDs.filter { it != myID }.forEach { peerID ->
            sendOrRoute(wire, peerID)
        }
    }

    private fun chachaPoly(key: ByteArray) = ChaCha20Poly1305(key)

    // -----------------------------------------------------------------------
    // Handle incoming wire message
    // -----------------------------------------------------------------------

    private fun handleIncomingWireMessage(message: WireMessage, fromTransportID: String, isTCP: Boolean) {
        // Verify signature if we know the peer
        val knownPeer = knownPeers[message.senderID]
        if (knownPeer != null) {
            val valid = try {
                WireMessageBuilder.verify(message, knownPeer.signingKeyPublic, identity)
            } catch (e: Exception) { false }
            if (!valid) return  // drop unsigned/tampered message
        }

        when (message.type) {
            WireMessageType.hello.name             -> handleHello(message, fromTransportID, isTCP)
            WireMessageType.initiateSession.name   -> handleInitiateSession(message)
            WireMessageType.message.name           -> handleMessage(message)
            WireMessageType.ack.name               -> handleAck(message)
            WireMessageType.relay.name             -> handleRelay(message, fromTransportID, isTCP)
            WireMessageType.groupMessage.name      -> handleGroupMessage(message)
            WireMessageType.groupMemberLeft.name   -> handleGroupMemberLeft(message)
            WireMessageType.groupDeleted.name      -> handleGroupDeleted(message)
            WireMessageType.typing.name            -> handleTyping(message)
            WireMessageType.reaction.name          -> handleReaction(message)
            WireMessageType.groupReaction.name     -> handleGroupReaction(message)
            WireMessageType.senderKeyRequest.name          -> handleSenderKeyRequest(message)
            WireMessageType.storeAndForward.name           -> handleStoreAndForward(message)
            WireMessageType.storeAndForwardDelivery.name   -> handleStoreAndForwardDelivery(message, fromTransportID, isTCP)
            WireMessageType.deadDrop.name                  -> handleDeadDrop(message, fromTransportID, isTCP)
            WireMessageType.deviceLinkRequest.name         -> handleDeviceLinkRequest(message)
            WireMessageType.deviceSyncMessage.name         -> handleDeviceSyncMessage(message)
            WireMessageType.remoteWipe.name                -> handleRemoteWipe(message)
            // DHT messages — rate-limited, dispatched to DHTEngine
            WireMessageType.dhtPing.name,
            WireMessageType.dhtPong.name,
            WireMessageType.dhtFindNode.name,
            WireMessageType.dhtFindNodeResp.name,
            WireMessageType.dhtStore.name,
            WireMessageType.dhtFindValue.name,
            WireMessageType.dhtFindValueResp.name -> {
                if (isDHTRateLimitOk(message.senderID)) {
                    val engine = dhtEngine
                    if (engine != null) {
                        dhtScope.launch { engine.handleMessage(message, message.senderID) }
                    }
                }
            }
            // readReceipt, groupReadReceipt, editMessage, groupEditMessage,
            // channelAnnouncement are accepted but not yet acted upon.
        }
    }

    private fun isDHTRateLimitOk(senderID: String): Boolean {
        val now = System.currentTimeMillis()
        val windowMs = 60_000L
        val maxPerWindow = 30
        val (windowStart, count) = dhtRateLimiters[senderID] ?: Pair(now, 0)
        return if (now - windowStart > windowMs) {
            dhtRateLimiters[senderID] = Pair(now, 1)
            true
        } else if (count < maxPerWindow) {
            dhtRateLimiters[senderID] = Pair(windowStart, count + 1)
            true
        } else {
            false
        }
    }

    // -----------------------------------------------------------------------
    // Hello
    // -----------------------------------------------------------------------

    private fun handleHello(message: WireMessage, fromTransportID: String, isTCP: Boolean) {
        val hello = try { json.decodeFromString<HelloMessage>(String(message.payload)) }
                    catch (e: Exception) { return }
        val bundle = hello.bundle
        val peerID = bundle.peerID

        peerBundles[peerID] = bundle

        // Map transport ID → peerID
        if (isTCP) {
            tcpPeerIDs[peerID] = true
        } else {
            endpointToPeerID[fromTransportID] = peerID
            peerIDToEndpoint[peerID] = fromTransportID
        }

        // Upsert known peer
        if (knownPeers[peerID] == null) {
            val peer = KnownPeer(
                id = peerID, username = bundle.username,
                signingKeyPublic = bundle.signingKeyPublic,
                dhKeyPublic = bundle.dhIdentityKeyPublic,
                safetyNumber = IdentityManager.safetyNumber(
                    identity.publicIdentity.signingKeyPublic, bundle.signingKeyPublic,
                    identity.publicIdentity.dhKeyPublic, bundle.dhIdentityKeyPublic
                ),
                lastSeen = Date(), isOnline = true, isDirectlyConnected = true,
                tcpAddress = bundle.tcpAddress
            )
            knownPeers[peerID] = peer
            delegate?.didDiscoverPeer(peer)
        } else {
            knownPeers[peerID] = knownPeers[peerID]?.copy(isOnline = true, lastSeen = Date()) ?: return
        }

        // Drain pending queue — now that we have the bundle, build and send each queued message
        pendingQueue.remove(peerID)?.forEach { (pendingBody, msgID) ->
            val wire = buildOutboundWire(peerID, pendingBody, msgID) ?: return@forEach
            sendOrRoute(wire, peerID)
        }
    }

    // -----------------------------------------------------------------------
    // InitiateSession (X3DH responder)
    // -----------------------------------------------------------------------

    private fun handleInitiateSession(message: WireMessage) {
        val msg = try { json.decodeFromString<InitiateSessionMessage>(String(message.payload)) }
                  catch (e: Exception) { return }
        val peerID = msg.senderBundle.peerID

        // Reject replayed or duplicate initiateSession: only accept if the incoming
        // message is strictly newer than the session we already have.
        val incomingTs = message.timestamp.time
        val existingTs = sessionCreatedAt[peerID]
        if (existingTs != null && incomingTs <= existingTs) return

        try {
            // Consume OTP if used
            val otpk: DHKeyPair? = msg.usedOneTimePreKeyId?.let { preKeys.consumeOneTimePreKey(it) }

            // X3DH receiver
            val sharedSecret = X3DH.initiateReceiver(
                recipientIdentityDH   = identity.dhIdentityKeyPair,
                recipientSignedPreKey = preKeys.signedPreKeyPair,
                recipientOneTimePreKey = otpk,
                senderIdentityDHKeyBytes   = msg.senderBundle.dhIdentityKeyPublic,
                senderEphemeralKeyBytes    = msg.ephemeralPublicKey
            )

            val dr = DoubleRatchet.initAsResponder(sharedSecret, preKeys.signedPreKeyPair)
            synchronized(sessionLock) {
                sessions[peerID] = dr
                sessionCreatedAt[peerID] = incomingTs
            }

            // Decrypt the first message — hold the lock so concurrent sends cannot
            // race against the freshly installed session state.
            val ratchetMsg = msg.initialMessage.fromWire()
            val plaintext  = synchronized(sessionLock) { dr.decrypt(ratchetMsg) }
            val content    = json.decodeFromString<MessageContent>(String(plaintext))

            val stored = StoredMessage(
                peerID = peerID, direction = MessageDirection.received.name,
                body = content.body, status = MessageStatus.delivered.name
            )
            messageStore.store(stored)
            delegate?.didReceiveMessage(stored, peerID)
            forwardToLinkedDevices(stored)

            // Send ACK
            val ack = AckMessage(messageID = stored.id, status = "delivered")
            val ackWire = builder().build(WireMessageType.ack.name, ack)
            sendOrRoute(ackWire, peerID)

        } catch (e: Exception) {
            delegate?.didEncounterError(e)
        }
    }

    // -----------------------------------------------------------------------
    // Message (Double Ratchet decrypt)
    // -----------------------------------------------------------------------

    private fun handleMessage(message: WireMessage) {
        val peerID = message.senderID
        val payload = try { json.decodeFromString<ChatMessagePayload>(String(message.payload)) }
                      catch (e: Exception) { return }
        val dr = synchronized(sessionLock) { sessions[peerID] } ?: return

        try {
            val plaintext = synchronized(sessionLock) { dr.decrypt(payload.ratchetMessage.fromWire()) }
            val content   = json.decodeFromString<MessageContent>(String(plaintext))

            // Group invite — parse and register, do not display as chat message
            if (content.type == "groupInvite") {
                content.groupInviteData?.let { inviteBytes ->
                    val invite = try { json.decodeFromString<GroupInvitePayload>(String(inviteBytes)) }
                                 catch (e: Exception) { null }
                    invite?.let {
                        val group = GroupInfo(
                            id = it.groupID, name = it.groupName,
                            memberIDs = it.memberIDs, creatorID = it.creatorID
                        )
                        groups[group.id] = group
                        saveGroups(groups.values.toList())
                        it.senderChainKey?.let { ck ->
                            saveSenderKey(it.groupID, it.creatorID,
                                SenderKeyState(chainKey = ck, iteration = it.senderIteration ?: 0L))
                        }
                        val myID = identity.publicIdentity.peerID
                        if (it.memberIDs.contains(myID) && loadSenderKey(group.id, myID) == null) {
                            val ck = ByteArray(32).also { k -> SecureRandom().nextBytes(k) }
                            saveSenderKey(group.id, myID, SenderKeyState(chainKey = ck))
                        }
                    }
                }
                return
            }

            val stored = StoredMessage(
                id = payload.messageID, peerID = peerID,
                direction = MessageDirection.received.name,
                body = content.body, status = MessageStatus.delivered.name,
                replyToID = content.replyToID,
                expiresAt = content.expiresAt?.time
            )
            messageStore.store(stored)
            delegate?.didReceiveMessage(stored, peerID)
            forwardToLinkedDevices(stored)

            // ACK
            val ack = AckMessage(messageID = payload.messageID, status = "delivered")
            val ackWire = builder().build(WireMessageType.ack.name, ack)
            sendOrRoute(ackWire, peerID)

        } catch (e: Exception) { delegate?.didEncounterError(e) }
    }

    // -----------------------------------------------------------------------
    // Ack
    // -----------------------------------------------------------------------

    private fun handleAck(message: WireMessage) {
        val ack = try { json.decodeFromString<AckMessage>(String(message.payload)) }
                  catch (e: Exception) { return }
        messageStore.updateStatus(ack.messageID, message.senderID, MessageStatus.delivered)
        delegate?.messageDelivered(ack.messageID, message.senderID)
    }

    // -----------------------------------------------------------------------
    // Typing
    // -----------------------------------------------------------------------

    private fun handleTyping(message: WireMessage) {
        val typing = try { json.decodeFromString<TypingMessage>(String(message.payload)) }
                     catch (e: Exception) { return }
        delegate?.didUpdateTypingState(message.senderID, typing.isTyping)
    }

    private fun handleReaction(message: WireMessage) {
        val senderID = message.senderID
        val dr = synchronized(sessionLock) { sessions[senderID] } ?: return
        val plain = try {
            val payload = json.decodeFromString<ChatMessagePayload>(String(message.payload))
            synchronized(sessionLock) { dr.decrypt(payload.ratchetMessage.fromWire()) }
        } catch (e: Exception) { return }
        val r = try { json.decodeFromString<ReactionMessage>(String(plain)) } catch (e: Exception) { return }
        delegate?.didReceiveReaction(senderID, r.targetMessageID, r.emoji)
    }

    private fun handleGroupReaction(message: WireMessage) {
        val r = try { json.decodeFromString<GroupReactionMessage>(String(message.payload)) }
                catch (e: Exception) { return }
        delegate?.didReceiveReaction(r.groupID, r.targetMessageID, r.emoji, senderID = message.senderID)
    }

    // -----------------------------------------------------------------------
    // Relay
    // -----------------------------------------------------------------------

    private fun handleRelay(message: WireMessage, fromTransportID: String, isTCP: Boolean) {
        val envelope = try { json.decodeFromString<RelayEnvelope>(String(message.payload)) }
                       catch (e: Exception) { return }
        if (envelope.ttl == 0) return

        val myPeerID = identity.publicIdentity.peerID
        if (envelope.targetPeerID == myPeerID) {
            // Destined for us — process inner message
            handleIncomingWireMessage(envelope.message, fromTransportID, isTCP)
        } else {
            // Forward: prefer Nearby (GMS), fall back to TCP broadcast (non-GMS / mDNS peers)
            val forwarded = envelope.forwarded()
            val forwardedWire = builder().build(WireMessageType.relay.name, forwarded)
            if (nearby != null) {
                val fromEndpoint = if (isTCP) null else fromTransportID
                nearby.broadcast(forwardedWire, excluding = fromEndpoint)
            } else {
                // Non-GMS path: relay over TCP connections (Wi-Fi Direct / mDNS)
                tcp.broadcast(forwardedWire, excluding = if (isTCP) fromTransportID else null)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Sender key request — re-distribute our current sender key for a group
    // -----------------------------------------------------------------------

    private fun handleSenderKeyRequest(message: WireMessage) {
        val req = try { json.decodeFromString<SenderKeyRequestMessage>(String(message.payload)) }
                  catch (e: Exception) { return }
        val myID = identity.publicIdentity.peerID
        // Only respond if the request targets us
        if (req.targetPeerID != myID) return
        val group = groups[req.groupID] ?: return
        val state = loadSenderKey(req.groupID, myID) ?: return

        val invite = GroupInvitePayload(
            groupID = group.id,
            groupName = group.name,
            memberIDs = group.memberIDs,
            creatorID = group.creatorID,
            senderChainKey = state.chainKey,
            senderIteration = state.iteration
        )
        val wire = buildOutboundGroupInvite(message.senderID, json.encodeToString(invite).toByteArray())
            ?: return
        sendOrRoute(wire, message.senderID)
    }

    // -----------------------------------------------------------------------
    // Device link — incoming link request (other device scanned our QR)
    // -----------------------------------------------------------------------

    private fun handleDeviceLinkRequest(message: WireMessage) {
        val msg = try { json.decodeFromString<DeviceLinkRequestMessage>(String(message.payload)) }
                  catch (e: Exception) { return }
        val bundle = msg.bundle
        val peerID = bundle.peerID

        peerBundles[peerID] = bundle

        val existing = knownPeers[peerID]
        if (existing == null) {
            val peer = KnownPeer(
                id = peerID, username = msg.deviceLabel,
                signingKeyPublic = bundle.signingKeyPublic,
                dhKeyPublic      = bundle.dhIdentityKeyPublic,
                safetyNumber     = IdentityManager.safetyNumber(
                    identity.publicIdentity.signingKeyPublic, bundle.signingKeyPublic,
                    identity.publicIdentity.dhKeyPublic, bundle.dhIdentityKeyPublic
                ),
                lastSeen = Date(), isOnline = true
            )
            knownPeers[peerID] = peer
            delegate?.didDiscoverPeer(peer)
        } else {
            knownPeers[peerID] = existing.copy(isOnline = true, lastSeen = Date())
        }

        linkedDeviceIDs[peerID] = true
        saveLinkedDevices()

        // Send a reciprocal link so the initiator knows us too
        val reply = DeviceLinkRequestMessage(
            deviceLabel = android.os.Build.MODEL,
            bundle      = preKeys.generateBundle(myTCPAddress)
        )
        val wire = builder().build(WireMessageType.deviceLinkRequest.name, reply)
        sendOrRoute(wire, peerID)
    }

    /** Receive a device-sync message from a linked device and store it locally. */
    private fun handleDeviceSyncMessage(message: WireMessage) {
        // Only accept from devices we explicitly linked
        if (!linkedDeviceIDs.containsKey(message.senderID)) return
        val sync = try { json.decodeFromString<DeviceSyncMessage>(String(message.payload)) }
                   catch (e: Exception) { return }
        val stored = try { json.decodeFromString<StoredMessage>(String(sync.messageJSON)) }
                     catch (e: Exception) { return }
        // Dedup
        if (messageStore.loadMessages(stored.peerID).any { it.id == stored.id }) return
        messageStore.store(stored)
        delegate?.didReceiveMessage(stored, stored.peerID)
    }

    /**
     * Forward a message to all linked devices for cross-device sync.
     * Skips forwarding if the message came from a linked device (loop prevention).
     */
    private fun forwardToLinkedDevices(stored: StoredMessage) {
        if (linkedDeviceIDs.isEmpty()) return
        // Don't re-forward messages that originated from a linked device
        if (linkedDeviceIDs.containsKey(stored.peerID)) return
        val msgJson = json.encodeToString(stored).toByteArray()
        val sync    = DeviceSyncMessage(messageJSON = msgJson)
        val wire    = builder().build(WireMessageType.deviceSyncMessage.name, sync)
        linkedDeviceIDs.keys().toList().forEach { deviceID ->
            sendOrRoute(wire, deviceID)
        }
    }

    // -----------------------------------------------------------------------
    // Store-and-forward
    // -----------------------------------------------------------------------

    /** Receive a store-and-forward request: store the sealed message for later delivery. */
    private fun handleStoreAndForward(message: WireMessage) {
        val req = try { json.decodeFromString<StoreAndForwardRequest>(String(message.payload)) }
                  catch (e: Exception) { return }

        // Drop already-expired requests
        if (req.expiresAt.time < System.currentTimeMillis()) return

        val queue = storeAndForwardQueue.getOrPut(req.targetPeerID) {
            java.util.Collections.synchronizedList(mutableListOf())
        }
        synchronized(queue) {
            // Dedup by messageID
            if (queue.any { it.messageID == req.messageID }) return
            // Enforce per-peer cap
            if (queue.size >= SAF_MAX_PER_PEER) queue.removeAt(0)
            queue.add(req)
        }
    }

    /** Receive a store-and-forward delivery: process each contained sealed message. */
    private fun handleStoreAndForwardDelivery(message: WireMessage, fromTransportID: String, isTCP: Boolean) {
        val delivery = try { json.decodeFromString<StoreAndForwardDelivery>(String(message.payload)) }
                       catch (e: Exception) { return }
        delivery.items.forEach { item ->
            val innerPayload = json.encodeToString(item.sealed).toByteArray()
            val inner = WireMessage(
                type      = WireMessageType.sealed.name,
                payload   = innerPayload,
                senderID  = message.senderID,
                timestamp = message.timestamp,
                signature = message.signature
            )
            handleIncomingWireMessage(inner, fromTransportID, isTCP)
        }
    }

    /** Receive a dead-drop: dedup, store, flood forward, and deliver if addressed to us. */
    private fun handleDeadDrop(message: WireMessage, fromTransportID: String, isTCP: Boolean) {
        val envelope = try { json.decodeFromString<DeadDropEnvelope>(String(message.payload)) }
                       catch (e: Exception) { return }

        // Drop expired
        if (envelope.expiresAt.time < System.currentTimeMillis()) return

        // Dedup
        val now = System.currentTimeMillis()
        if (seenDeadDropIDs.putIfAbsent(envelope.id, now) != null) return

        // Store for later delivery to offline peers
        synchronized(deadDropLock) { deadDrops.add(envelope) }

        // Flood to other connected peers (TTL is tracked externally via expiresAt)
        val forwardWire = builder().build(WireMessageType.deadDrop.name, envelope)
        if (nearby != null) {
            val fromEndpoint = if (isTCP) null else fromTransportID
            nearby.broadcast(forwardWire, excluding = fromEndpoint)
        } else {
            tcp.broadcast(forwardWire, excluding = if (isTCP) fromTransportID else null)
        }

        // Deliver if addressed to us
        val myPeerID = identity.publicIdentity.peerID
        if (envelope.targetPeerID == myPeerID) {
            val inner = WireMessage(
                type      = WireMessageType.sealed.name,
                payload   = json.encodeToString(envelope.sealed).toByteArray(),
                senderID  = message.senderID,
                timestamp = message.timestamp,
                signature = message.signature
            )
            handleIncomingWireMessage(inner, fromTransportID, isTCP)
        }
    }

    /**
     * Called when a peer connects (after Hello).
     * Drains the store-and-forward queue and dead drops addressed to this peer.
     */
    private fun deliverQueuedMessages(peerID: String) {
        // --- Store-and-forward queue ---
        val items = storeAndForwardQueue.remove(peerID)
        if (!items.isNullOrEmpty()) {
            val deliveryItems = items.map { req ->
                StoreAndForwardItem(messageID = req.messageID, sealed = req.sealed)
            }
            val delivery = StoreAndForwardDelivery(items = deliveryItems)
            val wire = builder().build(WireMessageType.storeAndForwardDelivery.name, delivery)
            sendOrRoute(wire, peerID)
        }

        // --- Dead drops ---
        val now = System.currentTimeMillis()
        val toDeliver = synchronized(deadDropLock) {
            deadDrops.filter { it.targetPeerID == peerID && it.expiresAt.time > now }
        }
        toDeliver.forEach { envelope ->
            val wire = builder().build(WireMessageType.deadDrop.name, envelope)
            sendOrRoute(wire, peerID)
        }
    }

    /** Remove expired store-and-forward items and dead drops. Call periodically. */
    private fun purgeExpiredQueueItems() {
        val now = System.currentTimeMillis()
        // Store-and-forward
        storeAndForwardQueue.forEach { (peerID, queue) ->
            synchronized(queue) { queue.removeAll { it.expiresAt.time <= now } }
            if (queue.isEmpty()) storeAndForwardQueue.remove(peerID)
        }
        // Dead drops
        synchronized(deadDropLock) {
            deadDrops.removeAll { it.expiresAt.time <= now }
        }
        // Seen IDs older than SAF_TTL_MS
        seenDeadDropIDs.entries.removeAll { (_, ts) -> now - ts > SAF_TTL_MS }
    }

    // -----------------------------------------------------------------------
    // Remote Wipe
    // -----------------------------------------------------------------------

    fun addTrustedWipePeer(peerID: String) {
        trustedWipePeers.add(peerID)
        saveTrustedWipePeers()
    }

    fun removeTrustedWipePeer(peerID: String) {
        trustedWipePeers.remove(peerID)
        saveTrustedWipePeers()
    }

    fun trustedWipePeersList(): List<String> = trustedWipePeers.toList()

    fun sendRemoteWipe(toPeerID: String) {
        val wire = builder().build(WireMessageType.remoteWipe.name, RemoteWipeRequest())
        sendOrRoute(wire, toPeerID)
    }

    private fun loadTrustedWipePeers(): MutableSet<String> {
        val raw = groupPrefs.getString("trusted_wipe_peers", null) ?: return mutableSetOf()
        return try { json.decodeFromString<List<String>>(raw).toMutableSet() }
               catch (_: Exception) { mutableSetOf() }
    }

    private fun saveTrustedWipePeers() {
        groupPrefs.edit().putString("trusted_wipe_peers", json.encodeToString(trustedWipePeers.toList())).apply()
    }

    private fun handleRemoteWipe(message: WireMessage) {
        // Only accept from trusted peers
        if (!trustedWipePeers.contains(message.senderID)) return
        val req = try { json.decodeFromString<RemoteWipeRequest>(String(message.payload)) }
                  catch (_: Exception) { return }
        // Dedup — prevent replay
        if (seenWipeRequestIDs.putIfAbsent(req.requestID, true) != null) return
        delegate?.didReceiveRemoteWipeRequest()
    }

    // -----------------------------------------------------------------------
    // Hello builder
    // -----------------------------------------------------------------------

    private fun buildHello(): WireMessage {
        val bundle = preKeys.generateBundle(myTCPAddress)
        return builder().build(WireMessageType.hello.name, HelloMessage(bundle))
    }

    private fun builder() = WireMessageBuilder(identity)

    // -----------------------------------------------------------------------
    // Nearby listener
    // -----------------------------------------------------------------------

    private val nearbyListener = object : NearbyManagerListener {
        override fun didDiscoverPeer(endpointId: String, displayName: String) {}
        override fun didLosePeer(endpointId: String) {}
        override fun didConnectToPeer(endpointId: String) {}
        override fun didDisconnectFromPeer(endpointId: String) {
            val peerID = endpointToPeerID.remove(endpointId)
            if (peerID != null) {
                peerIDToEndpoint.remove(peerID)
                knownPeers[peerID] = knownPeers[peerID]?.copy(isOnline = false) ?: return
                delegate?.peerDidDisconnect(peerID)
            }
        }
        override fun didReceiveMessage(message: WireMessage, fromEndpointId: String) {
            handleIncomingWireMessage(message, fromEndpointId, isTCP = false)
        }
        override fun sendDidFail(endpointId: String, error: Exception) {
            delegate?.didEncounterError(error)
        }
        override fun helloMessage(): WireMessage = buildHello()
    }

    // -----------------------------------------------------------------------
    // TCP listener
    // -----------------------------------------------------------------------

    private val tcpListener = object : TcpTransportListener {
        override fun didConnect(peerID: String, address: String) {
            if (address.isNotEmpty()) tcpAddressToPeerID[address] = peerID
            // Flush any queued DHT messages for this address
            val queued = pendingDHTMessages.remove(address) ?: return
            dhtScope.launch {
                for (msg in queued) {
                    runCatching { tcp.send(msg, peerID) }
                }
            }
        }
        override fun didDisconnect(peerID: String) {
            tcpPeerIDs.remove(peerID)
            tcpAddressToPeerID.entries.removeIf { it.value == peerID }
            knownPeers[peerID] = knownPeers[peerID]?.copy(isOnline = false) ?: return
            delegate?.peerDidDisconnect(peerID)
        }
        override fun didReceiveMessage(message: WireMessage, fromPeerID: String) {
            handleIncomingWireMessage(message, fromPeerID, isTCP = true)
        }
        override fun didStartListening(port: Int) {}
        override fun didFailToSend(peerID: String, error: Exception) {
            delegate?.didEncounterError(error)
        }
    }

    // -----------------------------------------------------------------------
    // Accessors for UI
    // -----------------------------------------------------------------------

    fun knownPeersList(): List<KnownPeer> = knownPeers.values.toList()
    fun messages(peerID: String): List<StoredMessage> = messageStore.loadMessages(peerID)
}

// ---------------------------------------------------------------------------
// Wire message builder (Android port)
// ---------------------------------------------------------------------------

class WireMessageBuilder(private val identity: IdentityManager) {
    private val json = Json { ignoreUnknownKeys = true }

    inline fun <reified T> build(type: String, payload: T): WireMessage {
        val payloadBytes = json.encodeToString(payload).toByteArray()
        val senderID  = identity.publicIdentity.peerID
        val timestamp = Date()
        val unsigned = WireMessage(type, payloadBytes, senderID, timestamp, ByteArray(0))
        val signature = identity.sign(unsigned.signingBytes())
        return WireMessage(type, payloadBytes, senderID, timestamp, signature)
    }

    companion object {
        fun verify(message: WireMessage, signingKeyPublic: ByteArray, identity: IdentityManager): Boolean =
            IdentityManager.verify(message.signature, message.signingBytes(), signingKeyPublic)
    }
}

// ---------------------------------------------------------------------------
// Extension: convert between internal and wire RatchetMessage
// ---------------------------------------------------------------------------

private fun com.sophax.sophaxchat.crypto.RatchetMessage.toWire() = RatchetMessage(
    encryptedHeader = this.encryptedHeader,
    ciphertext      = this.ciphertext
)

private fun RatchetMessage.fromWire() = com.sophax.sophaxchat.crypto.RatchetMessage(
    encryptedHeader = this.encryptedHeader,
    ciphertext      = this.ciphertext
)
