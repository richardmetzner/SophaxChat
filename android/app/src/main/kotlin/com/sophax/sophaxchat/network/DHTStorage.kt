package com.sophax.sophaxchat.network

// DHTStorage.kt
// SophaxChat — Android
//
// Persists the KBucketTable snapshot to encrypted storage via EncryptedSharedPreferences.
// Survives app restarts so we don't cold-bootstrap every time.
// Kotlin port of iOS DHTStorage.swift.

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class DHTStorage(private val context: Context) {

    companion object {
        private const val PREFS_NAME = "sophaxchat_dht"
        private const val KEY_KBUCKETS = "kbuckets_snapshot"
    }

    private val json = Json { ignoreUnknownKeys = true }

    private val prefs by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context, PREFS_NAME, masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    // MARK: - Persist

    /** Saves the k-bucket snapshot (list of DHTContact lists) to encrypted storage. */
    fun save(snapshot: List<List<DHTContact>>) {
        val encoded = try { json.encodeToString(snapshot) } catch (_: Exception) { return }
        prefs.edit().putString(KEY_KBUCKETS, encoded).apply()
    }

    /** Loads and decodes the previously saved k-bucket snapshot.
     *  Returns an empty list if no snapshot exists or decoding fails. */
    fun load(): List<DHTContact> {
        val raw = prefs.getString(KEY_KBUCKETS, null) ?: return emptyList()
        return try {
            json.decodeFromString<List<List<DHTContact>>>(raw).flatten()
        } catch (_: Exception) {
            emptyList()
        }
    }
}
