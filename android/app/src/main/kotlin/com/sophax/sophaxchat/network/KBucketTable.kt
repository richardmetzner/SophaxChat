package com.sophax.sophaxchat.network

// KBucketTable.kt
// SophaxChat — Android
//
// Kademlia routing table: 256 k-buckets indexed by XOR distance, k=20.
// Kotlin port of iOS KBucket.swift — identical bucket-index algorithm.
// Thread safety: all mutations guarded by a Mutex (call from coroutines).

import com.sophax.sophaxchat.crypto.toHex
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.Date

// ---------------------------------------------------------------------------
// DHTNodeID
// ---------------------------------------------------------------------------

data class DHTNodeID(val bytes: ByteArray) {

    init { require(bytes.size == 32) { "DHTNodeID must be 32 bytes, got ${bytes.size}" } }

    val hexString: String get() = bytes.toHex()

    /** XOR distance to another node — 32-byte big-endian result. */
    fun xorDistance(to: DHTNodeID): ByteArray =
        ByteArray(32) { i -> (bytes[i].toInt() xor to.bytes[i].toInt()).toByte() }

    /**
     * Kademlia bucket index: position of the highest set bit in the XOR distance (0–255).
     * Returns -1 if distance == 0 (same node).
     */
    fun bucketIndex(to: DHTNodeID): Int {
        val d = xorDistance(to)
        for (byteIdx in d.indices) {
            val byte = d[byteIdx].toInt() and 0xFF
            if (byte == 0) continue
            for (bitIdx in 7 downTo 0) {
                if (byte and (1 shl bitIdx) != 0) {
                    return (d.size - 1 - byteIdx) * 8 + bitIdx
                }
            }
        }
        return -1  // same node
    }

    /** Lexicographic comparison for XOR-distance sorting. */
    fun distanceLessThan(a: DHTNodeID, b: DHTNodeID): Boolean {
        val da = xorDistance(a)
        val db = xorDistance(b)
        for (i in da.indices) {
            val ai = da[i].toInt() and 0xFF
            val bi = db[i].toInt() and 0xFF
            if (ai != bi) return ai < bi
        }
        return false
    }

    override fun equals(other: Any?) = other is DHTNodeID && bytes.contentEquals(other.bytes)
    override fun hashCode() = bytes.contentHashCode()

    companion object {
        fun from(hex: String): DHTNodeID {
            require(hex.length == 64) { "DHTNodeID hex must be 64 chars, got ${hex.length}" }
            val bytes = ByteArray(32) { i ->
                hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
            return DHTNodeID(bytes)
        }
    }
}

// ---------------------------------------------------------------------------
// DHTContact
// ---------------------------------------------------------------------------

data class DHTContact(
    val nodeID: String,        // hex 64 chars
    val onionAddress: String,  // 62-char .onion hostname, no port
    val port: Int = 25519,
    var lastSeen: Long = System.currentTimeMillis(),
    var failCount: Int = 0
) {
    val tcpAddress: String get() = "$onionAddress:$port"
}

// ---------------------------------------------------------------------------
// KBucketTable
// ---------------------------------------------------------------------------

class KBucketTable(private val localNodeID: DHTNodeID) {

    companion object {
        const val K = 20
        private const val BUCKET_COUNT = 256
        private const val STALE_THRESHOLD_MS = 15 * 60 * 1000L
    }

    private val mutex = Mutex()
    private val buckets: Array<ArrayDeque<DHTContact>> =
        Array(BUCKET_COUNT) { ArrayDeque() }

    // MARK: - Core operations

    /** Insert or refresh a contact. Ignored if nodeID == localNodeID. */
    suspend fun insert(contact: DHTContact) = mutex.withLock {
        val contactID = runCatching { DHTNodeID.from(contact.nodeID) }.getOrNull() ?: return@withLock
        val idx = localNodeID.bucketIndex(contactID)
        if (idx < 0) return@withLock  // same node

        val bucket = buckets[idx]
        val existing = bucket.indexOfFirst { it.nodeID == contact.nodeID }
        if (existing >= 0) {
            // Refresh existing entry
            bucket[existing] = bucket[existing].copy(
                lastSeen = System.currentTimeMillis(), failCount = 0
            )
            return@withLock
        }

        if (bucket.size < K) {
            bucket.addLast(contact)
        } else {
            evictOrDiscard(contact, bucket)
        }
    }

    /** Returns up to [count] contacts closest to [target] by XOR distance. */
    suspend fun closestNodes(target: DHTNodeID, count: Int): List<DHTContact> = mutex.withLock {
        buckets.asSequence()
            .flatMap { it.asSequence() }
            .filter { it.nodeID != localNodeID.hexString }
            .sortedWith { a, b ->
                val aID = runCatching { DHTNodeID.from(a.nodeID) }.getOrNull() ?: return@sortedWith 0
                val bID = runCatching { DHTNodeID.from(b.nodeID) }.getOrNull() ?: return@sortedWith 0
                val da = target.xorDistance(aID)
                val db = target.xorDistance(bID)
                for (i in da.indices) {
                    val diff = (da[i].toInt() and 0xFF) - (db[i].toInt() and 0xFF)
                    if (diff != 0) return@sortedWith diff
                }
                0
            }
            .take(count)
            .toList()
    }

    /** Resets failCount and updates lastSeen. */
    suspend fun markSeen(nodeID: String) = mutex.withLock {
        forEachBucket { bucket ->
            val i = bucket.indexOfFirst { it.nodeID == nodeID }
            if (i >= 0) { bucket[i] = bucket[i].copy(lastSeen = System.currentTimeMillis(), failCount = 0) }
        }
    }

    /** Increments failCount; evicts after 3 consecutive failures. */
    suspend fun markFailed(nodeID: String) = mutex.withLock {
        forEachBucket { bucket ->
            val i = bucket.indexOfFirst { it.nodeID == nodeID }
            if (i >= 0) {
                val updated = bucket[i].copy(failCount = bucket[i].failCount + 1)
                if (updated.failCount >= 3) bucket.removeAt(i) else bucket[i] = updated
            }
        }
    }

    suspend fun remove(nodeID: String) = mutex.withLock {
        buckets.forEach { it.removeAll { c -> c.nodeID == nodeID } }
    }

    suspend fun allContacts(): List<DHTContact> = mutex.withLock {
        buckets.flatMap { it.toList() }
    }

    // MARK: - Persistence

    suspend fun snapshot(): List<List<DHTContact>> = mutex.withLock {
        buckets.map { it.toList() }
    }

    suspend fun restore(snapshot: List<List<DHTContact>>) = mutex.withLock {
        if (snapshot.size != BUCKET_COUNT) return@withLock
        snapshot.forEachIndexed { i, list ->
            buckets[i].clear()
            list.take(K).forEach { buckets[i].addLast(it) }
        }
    }

    // MARK: - Private

    private fun evictOrDiscard(contact: DHTContact, bucket: ArrayDeque<DHTContact>) {
        val staleAt = System.currentTimeMillis() - STALE_THRESHOLD_MS
        val evictIdx = bucket.indexOfFirst { it.failCount >= 1 && it.lastSeen < staleAt }
        if (evictIdx >= 0) bucket[evictIdx] = contact
        // else: bucket full of fresh contacts — discard new one (Kademlia spec)
    }

    private inline fun forEachBucket(action: (ArrayDeque<DHTContact>) -> Unit) {
        buckets.forEach { action(it) }
    }
}
