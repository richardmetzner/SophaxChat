package com.sophax.sophaxchat

import android.content.Context
import com.sophax.sophaxchat.crypto.DHKeyPair
import com.sophax.sophaxchat.crypto.DoubleRatchet
import com.sophax.sophaxchat.crypto.IdentityManager
import com.sophax.sophaxchat.crypto.PreKeyManager
import com.sophax.sophaxchat.crypto.X3DH
import com.sophax.sophaxchat.crypto.PreKeyBundleLocal
import com.sophax.sophaxchat.network.NearbyManager
import com.sophax.sophaxchat.network.NearbyManagerListener
import com.sophax.sophaxchat.network.TcpTransport
import com.sophax.sophaxchat.network.TcpTransportListener
import com.sophax.sophaxchat.protocol.*
import com.sophax.sophaxchat.storage.MessageDirection
import com.sophax.sophaxchat.storage.MessageStatus
import com.sophax.sophaxchat.storage.MessageStore
import com.sophax.sophaxchat.storage.StoredMessage
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
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
    fun messageDelivered(messageID: String, toPeerID: String)
    fun didEncounterError(error: Exception)
}

// ---------------------------------------------------------------------------
// ChatManager — coordinates crypto, transport, and storage
// Port of iOS ChatManager.swift (Phase 2 scope: 1-to-1 messaging + relay)
// ---------------------------------------------------------------------------

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

    // Messages queued while waiting for a peer's bundle
    private val pendingQueue = ConcurrentHashMap<String, ArrayDeque<Pair<WireMessage, String>>>()

    // Nearby endpoint ID → peerID (learned from Hello)
    private val endpointToPeerID = ConcurrentHashMap<String, String>()
    private val peerIDToEndpoint = ConcurrentHashMap<String, String>()

    // TCP connection: peerID → address (already tracked by TcpTransport)
    private val tcpPeerIDs = ConcurrentHashMap<String, Boolean>()

    // -----------------------------------------------------------------------
    // Transports
    // -----------------------------------------------------------------------

    val nearby = NearbyManager(context).also { it.listener = nearbyListener }
    val tcp    = TcpTransport(helloProvider = { buildHello() }).also { it.listener = tcpListener }

    // -----------------------------------------------------------------------
    // Start / Stop
    // -----------------------------------------------------------------------

    fun start() {
        preKeys.rotateIfNeeded()
        val displayName = "sx-${identity.publicIdentity.peerID.take(12)}"
        nearby.start(displayName)
        tcp.start()
    }

    fun stop() {
        nearby.stop()
        tcp.stop()
    }

    // -----------------------------------------------------------------------
    // Send message
    // -----------------------------------------------------------------------

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
            // No bundle yet — queue message
            pendingQueue.getOrPut(peerID) { ArrayDeque() }
                .add(Pair(WireMessage("", ByteArray(0), "", Date(), ByteArray(0)), messageID))
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
        when {
            tcp.isConnected(toPeerID) ->
                tcp.send(wire, toPeerID)

            peerIDToEndpoint[toPeerID] != null ->
                nearby.send(wire, peerIDToEndpoint[toPeerID]!!)

            nearby.connectedEndpointIDs().isNotEmpty() -> {
                // Relay via connected peers (sealed sender would be ideal; plain relay for now)
                val relay = RelayEnvelope(
                    id = UUID.randomUUID().toString(),
                    targetPeerID = toPeerID,
                    originPeerID = identity.publicIdentity.peerID,
                    ttl = RelayEnvelope.MAX_TTL,
                    hopCount = 0,
                    message = wire
                )
                val relayWire = builder().build(WireMessageType.relay.name, relay)
                nearby.broadcast(relayWire)
            }
        }
    }

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
            else -> { /* other types handled in Phase 3 */ }
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
            knownPeers[peerID] = knownPeers[peerID]!!.copy(isOnline = true, lastSeen = Date())
        }

        // Drain pending queue
        pendingQueue.remove(peerID)?.forEach { (_, msgID) ->
            sendMessage(peerID, "")  // re-send pending (simplified — body lost, just flush)
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
            IdentityManager.verify(message.signingBytes(), message.signature, signingKeyPublic)
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
