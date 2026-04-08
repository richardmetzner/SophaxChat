package com.sophax.sophaxchat.network

// DHTStore.kt
// SophaxChat — Android
//
// Local key-value store for DHT STORE requests.
// Kotlin port of iOS DHTStore.swift.
// Thread safety: Mutex-guarded.

import com.sophax.sophaxchat.protocol.PreKeyBundle
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class DHTStore {

    companion object {
        /** Default TTL — slightly longer than the 24h republish interval. */
        val DEFAULT_TTL_MS = 25L * 60 * 60 * 1000
    }

    private data class Entry(val bundle: PreKeyBundle, val expiresAt: Long)

    private val mutex = Mutex()
    /** nodeID(hex64) → Entry */
    private val entries = HashMap<String, Entry>()
    /** peerID(hex16) → nodeID(hex64) */
    private val prefixIndex = HashMap<String, String>()

    // MARK: - Mutations

    suspend fun store(
        nodeID: String,
        bundle: PreKeyBundle,
        expiresAt: Long = System.currentTimeMillis() + DEFAULT_TTL_MS
    ) = mutex.withLock {
        entries[nodeID] = Entry(bundle, expiresAt)
        prefixIndex[nodeID.take(16)] = nodeID
    }

    suspend fun remove(nodeID: String) = mutex.withLock {
        val prefix = nodeID.take(16)
        if (prefixIndex[prefix] == nodeID) prefixIndex.remove(prefix)
        entries.remove(nodeID)
    }

    suspend fun purgeExpired() = mutex.withLock {
        val now = System.currentTimeMillis()
        val expired = entries.filter { it.value.expiresAt < now }.keys.toList()
        for (key in expired) {
            val prefix = key.take(16)
            if (prefixIndex[prefix] == key) prefixIndex.remove(prefix)
            entries.remove(key)
        }
    }

    // MARK: - Queries

    /** Lookup by full 256-bit nodeID (hex64). */
    suspend fun lookup(nodeID: String): PreKeyBundle? = mutex.withLock {
        val entry = entries[nodeID] ?: return@withLock null
        if (entry.expiresAt < System.currentTimeMillis()) null else entry.bundle
    }

    /** Lookup by 16-char peerID prefix. */
    suspend fun lookupByPrefix(peerID: String): PreKeyBundle? = mutex.withLock {
        val nodeID = prefixIndex[peerID] ?: return@withLock null
        val entry = entries[nodeID] ?: return@withLock null
        if (entry.expiresAt < System.currentTimeMillis()) null else entry.bundle
    }

    /** Full nodeID for a given peerID prefix, if known. */
    suspend fun nodeIDForPeerID(peerID: String): String? = mutex.withLock {
        prefixIndex[peerID]
    }

    suspend fun allNodeIDs(): List<String> = mutex.withLock { entries.keys.toList() }
}
