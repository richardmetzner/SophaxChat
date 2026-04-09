package com.sophax.sophaxchat.network

// DHTEngine.kt
// SophaxChat — Android
//
// Kademlia DHT engine — peer discovery over Tor.
// Kotlin port of iOS DHTEngine.swift.
// Uses coroutines + Mutex instead of Swift actors.
//
// Usage:
//   1. val engine = DHTEngine(identity, wireBuilder, scope) { msg, contact -> ... }
//   2. engine.start(bootstrapContacts)
//   3. val (nodeID, bundle) = engine.lookup("a1b2c3d4e5f6a1b2")
//   4. engine.handleMessage(wireMessage, fromPeerID)

import com.sophax.sophaxchat.crypto.IdentityManager
import com.sophax.sophaxchat.crypto.toHex
import com.sophax.sophaxchat.protocol.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.util.UUID

// ---------------------------------------------------------------------------
// Send callback type
// ---------------------------------------------------------------------------

/** Suspending block that delivers a DHT WireMessage to a contact. */
typealias DHTSendBlock = suspend (WireMessage, DHTContact) -> Unit

// ---------------------------------------------------------------------------
// DHTEngine
// ---------------------------------------------------------------------------

class DHTEngine(
    private val identity:    IdentityManager,
    private val wireBuilder: WireMessageBuilder,
    private val scope:       CoroutineScope,
    private val send:        DHTSendBlock
) {
    companion object {
        const val K               = 20
        const val ALPHA           = 3
        const val QUERY_TIMEOUT   = 30_000L   // ms
        const val PUBLISH_INTERVAL = 24L * 60 * 60 * 1000
        const val REFRESH_INTERVAL = 60L * 60 * 1000
    }

    private val localNodeID: DHTNodeID
    private val localContact: DHTContact
    val table: KBucketTable
    val store: DHTStore

    init {
        val nodeBytes = run {
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(identity.publicIdentity.signingKeyPublic)
            digest.update(identity.publicIdentity.dhKeyPublic)
            digest.digest()
        }
        localNodeID  = DHTNodeID(nodeBytes)
        localContact = DHTContact(
            nodeID       = nodeBytes.toHex(),
            onionAddress = identity.publicIdentity.signingKeyPublic.let {
                runCatching { com.sophax.sophaxchat.crypto.OnionAddress.from(it) }.getOrDefault("")
            }
        )
        table = KBucketTable(localNodeID)
        store = DHTStore()
    }

    // MARK: - Lookup state

    private sealed class LookupResult {
        data class Found(val dhtNodeID: String, val bundle: PreKeyBundle) : LookupResult()
        data class NotFound(val closest: List<DHTContact>) : LookupResult()
    }

    private data class LookupState(
        val target:       DHTNodeID,
        val wantValue:    Boolean,
        val peerIDPrefix: String?,
        val queried:      MutableSet<String> = mutableSetOf(),
        val inFlight:     MutableSet<String> = mutableSetOf(),
        val closest:      MutableList<DHTContact> = mutableListOf(),
        val deferred:     CompletableDeferred<LookupResult> = CompletableDeferred()
    )

    private data class PendingQuery(
        val lookupID:    String,
        val wantValue:   Boolean,
        val timeoutJob:  Job
    )

    private val json = Json { ignoreUnknownKeys = true }

    private val stateMutex   = Mutex()
    private val activeLookups  = HashMap<String, LookupState>()   // lookupID → state
    private val pendingQueries = HashMap<String, PendingQuery>()   // peerNodeID → query

    private var stopped   = false
    private var publishJob: Job? = null
    private var refreshJob: Job? = null

    // MARK: - Lifecycle

    fun start(bootstrapContacts: List<DHTContact>) {
        stopped = false
        schedulePublish()
        scheduleRefresh()
        scope.launch { bootstrap(bootstrapContacts) }
    }

    fun stop() {
        stopped = true
        publishJob?.cancel(); publishJob = null
        refreshJob?.cancel(); refreshJob = null
        scope.launch {
            stateMutex.withLock {
                activeLookups.values.forEach {
                    it.deferred.completeExceptionally(Exception("DHT stopped"))
                }
                activeLookups.clear()
                pendingQueries.values.forEach { it.timeoutJob.cancel() }
                pendingQueries.clear()
            }
        }
    }

    // MARK: - Public API

    /** Lookup a peer by their 16-char peerID. Returns (dhtNodeID, PreKeyBundle) on success. */
    suspend fun lookup(peerID: String): Pair<String, PreKeyBundle>? {
        // Fast path: local store hit
        val cached = store.lookupByPrefix(peerID)
        val nodeID = store.nodeIDForPeerID(peerID)
        if (cached != null && nodeID != null) return Pair(nodeID, cached)

        val padded = peerID.padEnd(64, '0')
        val target = runCatching { DHTNodeID.from(padded) }.getOrNull() ?: return null
        return when (val result = iterativeLookup(target, wantValue = true, peerIDPrefix = peerID)) {
            is LookupResult.Found    -> Pair(result.dhtNodeID, result.bundle)
            is LookupResult.NotFound -> null
        }
    }

    /** Publish our own PreKeyBundle to the k nodes closest to our nodeID. */
    suspend fun publishSelf(bundle: PreKeyBundle) {
        val closest = table.closestNodes(localNodeID, K)
        if (closest.isEmpty()) return
        val expiry = java.util.Date(System.currentTimeMillis() + DHTStore.DEFAULT_TTL_MS)
        val payload = DHTStorePayload(nodeID = localNodeID.hexString, bundle = bundle, expiresAt = expiry)
        closest.forEach { contact ->
            val msg = runCatching { wireBuilder.build(WireMessageType.dhtStore.name, payload) }.getOrNull()
                ?: return@forEach
            send(msg, contact)
        }
    }

    /** Route an incoming DHT wire message. Called by ChatManager for all dht* types. */
    suspend fun handleMessage(message: WireMessage, fromPeerID: String) {
        table.markSeen(fromPeerID)
        when (WireMessageType.entries.find { it.name == message.type }) {
            WireMessageType.dhtPing         -> handlePing(message, fromPeerID)
            WireMessageType.dhtPong         -> handlePong(fromPeerID)
            WireMessageType.dhtFindNode     -> handleFindNode(message, fromPeerID)
            WireMessageType.dhtFindNodeResp -> handleFindNodeResp(message, fromPeerID)
            WireMessageType.dhtStore        -> handleStore(message)
            WireMessageType.dhtFindValue    -> handleFindValue(message, fromPeerID)
            WireMessageType.dhtFindValueResp -> handleFindValueResp(message, fromPeerID)
            else -> Unit
        }
    }

    // MARK: - Incoming handlers

    private suspend fun handlePing(message: WireMessage, fromPeerID: String) {
        val payload = runCatching { json.decodeFromString<DHTPingPayload>(String(message.payload)) }.getOrNull() ?: return
        val contact = contactInfo(fromPeerID, payload.senderNodeID) ?: return
        val pong = DHTPongPayload(senderNodeID = localNodeID.hexString)
        val msg  = runCatching { wireBuilder.build(WireMessageType.dhtPong.name, pong) }.getOrNull() ?: return
        send(msg, contact)
    }

    private suspend fun handlePong(fromPeerID: String) {
        resolvePendingQuery(fromPeerID, emptyList(), null)
    }

    private suspend fun handleFindNode(message: WireMessage, fromPeerID: String) {
        val payload = runCatching { json.decodeFromString<DHTFindNodePayload>(String(message.payload)) }.getOrNull() ?: return
        val target  = runCatching { DHTNodeID.from(payload.targetNodeID) }.getOrNull() ?: return
        val contact = contactInfo(fromPeerID, null) ?: return
        val closest = table.closestNodes(target, K)
        val resp = DHTFindNodeRespPayload(closestNodes = closest.map { it.toDHTNodeInfo() })
        val msg  = runCatching { wireBuilder.build(WireMessageType.dhtFindNodeResp.name, resp) }.getOrNull() ?: return
        send(msg, contact)
        table.insert(contact)
    }

    private suspend fun handleFindNodeResp(message: WireMessage, fromPeerID: String) {
        val payload  = runCatching { json.decodeFromString<DHTFindNodeRespPayload>(String(message.payload)) }.getOrNull() ?: return
        val contacts = payload.closestNodes.mapNotNull { it.toDHTContact() }
        resolvePendingQuery(fromPeerID, contacts, null)
    }

    private suspend fun handleStore(message: WireMessage) {
        val payload = runCatching { json.decodeFromString<DHTStorePayload>(String(message.payload)) }.getOrNull() ?: return
        store.store(payload.nodeID, payload.bundle, payload.expiresAt.time)
        store.purgeExpired()
    }

    private suspend fun handleFindValue(message: WireMessage, fromPeerID: String) {
        val payload = runCatching { json.decodeFromString<DHTFindValuePayload>(String(message.payload)) }.getOrNull() ?: return
        val contact = contactInfo(fromPeerID, null) ?: return

        var bundle = store.lookup(payload.targetNodeID)
        if (bundle == null && payload.peerIDPrefix != null) {
            bundle = store.lookupByPrefix(payload.peerIDPrefix)
        }

        val resp: DHTFindValueRespPayload
        if (bundle != null) {
            resp = DHTFindValueRespPayload(bundle = bundle, closestNodes = emptyList())
        } else {
            val target  = runCatching { DHTNodeID.from(payload.targetNodeID) }.getOrElse { localNodeID }
            val closest = table.closestNodes(target, K)
            resp = DHTFindValueRespPayload(bundle = null, closestNodes = closest.map { it.toDHTNodeInfo() })
        }

        val msg = runCatching { wireBuilder.build(WireMessageType.dhtFindValueResp.name, resp) }.getOrNull() ?: return
        send(msg, contact)
        table.insert(contact)
    }

    private suspend fun handleFindValueResp(message: WireMessage, fromPeerID: String) {
        val payload  = runCatching { json.decodeFromString<DHTFindValueRespPayload>(String(message.payload)) }.getOrNull() ?: return
        val contacts = payload.closestNodes.mapNotNull { it.toDHTContact() }
        resolvePendingQuery(fromPeerID, contacts, payload.bundle)
    }

    // MARK: - Iterative lookup

    private suspend fun iterativeLookup(
        target:       DHTNodeID,
        wantValue:    Boolean,
        peerIDPrefix: String? = null
    ): LookupResult {
        val lookupID = UUID.randomUUID().toString()
        val seed = table.closestNodes(target, ALPHA)
        if (seed.isEmpty()) return LookupResult.NotFound(emptyList())

        val state = LookupState(
            target       = target,
            wantValue    = wantValue,
            peerIDPrefix = peerIDPrefix
        )
        state.closest.addAll(seed)

        stateMutex.withLock { activeLookups[lookupID] = state }
        sendNextQueries(lookupID)

        return try {
            withTimeout(120_000L) { state.deferred.await() }
        } catch (_: TimeoutCancellationException) {
            stateMutex.withLock { activeLookups.remove(lookupID) }
            LookupResult.NotFound(emptyList())
        }
    }

    private suspend fun sendNextQueries(lookupID: String) {
        val state = stateMutex.withLock { activeLookups[lookupID] } ?: return

        val candidates = state.closest
            .filter { it.nodeID !in state.queried && it.nodeID !in state.inFlight }
            .take(ALPHA)

        if (candidates.isEmpty()) {
            if (state.inFlight.isEmpty()) {
                stateMutex.withLock { activeLookups.remove(lookupID) }
                state.deferred.complete(LookupResult.NotFound(state.closest.toList()))
            }
            return
        }

        for (contact in candidates) {
            stateMutex.withLock {
                activeLookups[lookupID]?.inFlight?.add(contact.nodeID)
            }

            val timeoutJob = scope.launch {
                delay(QUERY_TIMEOUT)
                table.markFailed(contact.nodeID)
                resolvePendingQuery(contact.nodeID, emptyList(), null)
            }
            stateMutex.withLock {
                pendingQueries[contact.nodeID] = PendingQuery(lookupID, state.wantValue, timeoutJob)
            }

            val msg = if (state.wantValue) {
                val p = DHTFindValuePayload(targetNodeID = state.target.hexString, peerIDPrefix = state.peerIDPrefix)
                runCatching { wireBuilder.build(WireMessageType.dhtFindValue.name, p) }.getOrNull()
            } else {
                val p = DHTFindNodePayload(targetNodeID = state.target.hexString)
                runCatching { wireBuilder.build(WireMessageType.dhtFindNode.name, p) }.getOrNull()
            }

            if (msg != null) {
                val c = contact
                scope.launch { send(msg, c) }
            }
        }
    }

    private suspend fun resolvePendingQuery(
        peerNodeID:   String,
        closestNodes: List<DHTContact>,
        bundle:       PreKeyBundle?
    ) {
        val pending = stateMutex.withLock { pendingQueries.remove(peerNodeID) } ?: return
        pending.timeoutJob.cancel()

        val state = stateMutex.withLock { activeLookups[pending.lookupID] } ?: return
        stateMutex.withLock {
            activeLookups[pending.lookupID]?.inFlight?.remove(peerNodeID)
            activeLookups[pending.lookupID]?.queried?.add(peerNodeID)
        }

        // Insert newly discovered contacts
        closestNodes.forEach { table.insert(it) }

        // Value found
        if (pending.wantValue && bundle != null) {
            val nodeID = state.peerIDPrefix?.let { prefix ->
                closestNodes.firstOrNull { it.nodeID.startsWith(prefix) }?.nodeID
            } ?: peerNodeID
            stateMutex.withLock { activeLookups.remove(pending.lookupID) }
            state.deferred.complete(LookupResult.Found(nodeID, bundle))
            return
        }

        // Merge new contacts into closest, keep k best
        val merged = (state.closest + closestNodes.filter { it.nodeID !in state.queried })
            .sortedWith { a, b ->
                val aID = runCatching { DHTNodeID.from(a.nodeID) }.getOrNull() ?: return@sortedWith 0
                val bID = runCatching { DHTNodeID.from(b.nodeID) }.getOrNull() ?: return@sortedWith 0
                val da = state.target.xorDistance(aID)
                val db = state.target.xorDistance(bID)
                for (i in da.indices) {
                    val diff = (da[i].toInt() and 0xFF) - (db[i].toInt() and 0xFF)
                    if (diff != 0) return@sortedWith diff
                }
                0
            }
            .take(K)
        stateMutex.withLock {
            activeLookups[pending.lookupID]?.closest?.apply { clear(); addAll(merged) }
        }

        sendNextQueries(pending.lookupID)
    }

    // MARK: - Bootstrap

    private suspend fun bootstrap(contacts: List<DHTContact>) {
        contacts.forEach { table.insert(it) }
        iterativeLookup(localNodeID, wantValue = false)
    }

    // MARK: - Periodic tasks

    private fun schedulePublish() {
        publishJob = scope.launch {
            while (!stopped) {
                delay(PUBLISH_INTERVAL)
                store.purgeExpired()
            }
        }
    }

    private fun scheduleRefresh() {
        refreshJob = scope.launch {
            var bucketIdx = 0
            while (!stopped) {
                delay(REFRESH_INTERVAL)
                // 1. Ping the least-recently-seen node in this bucket (liveness check).
                val lrs = table.leastRecentlySeen(bucketIdx)
                if (lrs != null) pingForRefresh(lrs)
                // 2. FIND_NODE to a random target — discovers new nodes, fills sparse buckets.
                val target = randomTargetInBucket(bucketIdx, localNodeID)
                if (target != null) iterativeLookup(target, wantValue = false)
                bucketIdx = (bucketIdx + 1) % 256
            }
        }
    }

    /** Sends a dhtPing to [contact] and registers a timeout via the pendingQueries mechanism.
     *  On pong, the timeout is cancelled via the normal resolvePendingQuery path.
     *  On timeout, queryTimedOut calls table.markFailed — eviction after 3 strikes. */
    private suspend fun pingForRefresh(contact: DHTContact) {
        val sentinelID = "ping_${contact.nodeID}"
        val alreadyInFlight = stateMutex.withLock { pendingQueries.containsKey(contact.nodeID) }
        if (alreadyInFlight) return

        val timeoutJob = scope.launch {
            delay(QUERY_TIMEOUT)
            table.markFailed(contact.nodeID)
            resolvePendingQuery(contact.nodeID, emptyList(), null)
        }
        stateMutex.withLock {
            pendingQueries[contact.nodeID] = PendingQuery(sentinelID, wantValue = false, timeoutJob)
        }

        val payload = DHTPingPayload(senderNodeID = localContact.nodeID)
        val msg = runCatching { wireBuilder.build(WireMessageType.dhtPing.name, payload) }.getOrNull()
        if (msg == null) {
            stateMutex.withLock { pendingQueries.remove(contact.nodeID) }
            timeoutJob.cancel()
            return
        }
        scope.launch { send(msg, contact) }
    }

    // MARK: - Helpers

    private suspend fun contactInfo(peerID: String, nodeID: String?): DHTContact? =
        table.allContacts().firstOrNull {
            it.nodeID.startsWith(peerID) || it.nodeID == nodeID
        }

    private fun randomTargetInBucket(idx: Int, localNodeID: DHTNodeID): DHTNodeID? {
        val bytes = localNodeID.bytes.copyOf()
        val bytePos = 31 - (idx / 8)
        val bitPos  = idx % 8
        bytes[bytePos] = (bytes[bytePos].toInt() xor (1 shl bitPos)).toByte()
        for (i in (bytePos + 1) until bytes.size) bytes[i] = (Math.random() * 256).toInt().toByte()
        if (bitPos > 0) {
            val mask = ((1 shl bitPos) - 1).toByte()
            bytes[bytePos] = (bytes[bytePos].toInt() and mask.toInt().inv() or
                    ((Math.random() * 256).toInt() and mask.toInt())).toByte()
        }
        return runCatching { DHTNodeID(bytes) }.getOrNull()
    }
}

// MARK: - Conversion helpers

private fun DHTContact.toDHTNodeInfo() = DHTNodeInfo(nodeID, onionAddress, port)

private fun DHTNodeInfo.toDHTContact(): DHTContact? {
    if (!onionAddress.endsWith(".onion") || onionAddress.length != 62) return null
    return DHTContact(nodeID = nodeID, onionAddress = onionAddress, port = port)
}

