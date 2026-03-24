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

    // Received peer bundles (for initiating X3DH)
    private val peerBundles  = ConcurrentHashMap<String, PreKeyBundle>()

    // Messages queued while waiting for a peer's bundle: Pair(body, messageID)
    private val pendingQueue = ConcurrentHashMap<String, ArrayDeque<Pair<String, String>>>()

    // Nearby endpoint ID → peerID (learned from Hello)
    private val endpointToPeerID = ConcurrentHashMap<String, String>()
    private val peerIDToEndpoint = ConcurrentHashMap<String, String>()

    // TCP connection: peerID → address (already tracked by TcpTransport)
    private val tcpPeerIDs = ConcurrentHashMap<String, Boolean>()

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
    }

    // -----------------------------------------------------------------------
    // Send message
    // -----------------------------------------------------------------------

    fun sendTyping(toPeerID: String) {
        val wire = builder().build(WireMessageType.typing.name, TypingMessage(isTyping = true))
        sendOrRoute(wire, toPeerID)
    }

    fun sendMessage(toPeerID: String, body: String) {
        val messageID = UUID.randomUUID().toString()

        // Store locally
        val stored = StoredMessage(
            id = messageID, peerID = toPeerID,
            direction = MessageDirection.sent.name, body = body,
            status = MessageStatus.sending.name
        )
        messageStore.store(stored)

        val wire = buildOutboundWire(toPeerID, body, messageID) ?: return
        sendOrRoute(wire, toPeerID)
    }

    // -----------------------------------------------------------------------
    // Build outbound wire (X3DH or DR encrypt)
    // -----------------------------------------------------------------------

    private fun buildOutboundWire(peerID: String, body: String, messageID: String): WireMessage? {
        val content = MessageContent(body = body, timestamp = Date())
        val contentBytes = json.encodeToString(content).toByteArray()

        // Case 1: existing DR session
        synchronized(sessionLock) { sessions[peerID] }?.let { dr ->
            return try {
                val payload = ChatMessagePayload(
                    ratchetMessage = dr.encrypt(contentBytes).toWire(),
                    messageID = messageID
                )
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
                val payload = ChatMessagePayload(
                    ratchetMessage = dr.encrypt(contentBytes).toWire(),
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
            WireMessageType.typing.name            -> handleTyping(message)
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
            synchronized(sessionLock) { sessions[peerID] = dr }

            // Decrypt the first message
            val ratchetMsg = msg.initialMessage.fromWire()
            val plaintext  = dr.decrypt(ratchetMsg)
            val content    = json.decodeFromString<MessageContent>(String(plaintext))

            val stored = StoredMessage(
                peerID = peerID, direction = MessageDirection.received.name,
                body = content.body, status = MessageStatus.delivered.name
            )
            messageStore.store(stored)
            delegate?.didReceiveMessage(stored, peerID)

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
            val plaintext = dr.decrypt(payload.ratchetMessage.fromWire())
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
                replyToID = content.replyToID
            )
            messageStore.store(stored)
            delegate?.didReceiveMessage(stored, peerID)

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
            // Forward
            val forwarded = envelope.forwarded()
            val forwardedWire = builder().build(WireMessageType.relay.name, forwarded)
            val fromEndpoint = if (isTCP) null else fromTransportID
            nearby.broadcast(forwardedWire, excluding = fromEndpoint)
        }
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
        override fun didConnect(peerID: String, address: String) {}
        override fun didDisconnect(peerID: String) {
            tcpPeerIDs.remove(peerID)
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
