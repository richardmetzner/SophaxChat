package com.sophax.sophaxchat.crypto

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.sophax.sophaxchat.protocol.PreKeyBundle
import java.security.SecureRandom
import java.util.Date
import java.util.concurrent.TimeUnit

/**
 * Manages X3DH prekeys — port of iOS PreKeyManager.swift.
 *
 * Keys stored in EncryptedSharedPreferences (equivalent to iOS Keychain):
 *   "spk_private", "spk_public", "spk_id", "spk_date" — signed prekey
 *   "otpk_ids"                                          — JSON list of OTP key IDs
 *   "otpk_<id>_private", "otpk_<id>_public"            — per OTP key pair
 */
class PreKeyManager(private val identity: IdentityManager, context: Context) {

    private val prefs: SharedPreferences = buildPrefs(context)

    // Signed prekey — lazily loaded
    private var _signedPreKeyPair: DHKeyPair? = null
    private var _signedPreKeyId: Long = 0L

    val signedPreKeyPair: DHKeyPair get() = _signedPreKeyPair ?: loadOrCreateSignedPreKey()
    val signedPreKeyId: Long get() = _signedPreKeyId

    init {
        loadOrCreateSignedPreKey()
        replenishIfNeeded()
    }

    // -----------------------------------------------------------------------
    // Bundle generation
    // -----------------------------------------------------------------------

    fun generateBundle(tcpAddress: String? = null): PreKeyBundle {
        val spk = signedPreKeyPair
        val spkSig = identity.sign(spk.publicKeyBytes)

        val otpkIds = loadOtpkIds()
        val otpkId = otpkIds.randomOrNull()
        val otpkPair = otpkId?.let { loadOtpkPair(it) }

        return PreKeyBundle(
            peerID              = identity.publicIdentity.peerID,
            username            = identity.publicIdentity.username,
            signingKeyPublic    = identity.publicIdentity.signingKeyPublic,
            dhIdentityKeyPublic = identity.publicIdentity.dhKeyPublic,
            signedPreKeyPublic  = spk.publicKeyBytes,
            signedPreKeyId      = _signedPreKeyId,
            signedPreKeySignature = spkSig,
            oneTimePreKeyPublic = otpkPair?.publicKeyBytes,
            oneTimePreKeyId     = otpkId,
            timestamp           = Date(),
            tcpAddress          = tcpAddress
        )
    }

    // -----------------------------------------------------------------------
    // OTP consumption
    // -----------------------------------------------------------------------

    fun consumeOneTimePreKey(id: Long): DHKeyPair? {
        val pair = loadOtpkPair(id) ?: return null
        deleteOtpk(id)
        replenishIfNeeded()
        return pair
    }

    // -----------------------------------------------------------------------
    // Key rotation
    // -----------------------------------------------------------------------

    fun rotateIfNeeded(maxAgeDays: Int = 7) {
        val dateStr = prefs.getString("spk_date", null) ?: return
        val date = dateStr.toLongOrNull()?.let { Date(it) } ?: return
        val ageMs = System.currentTimeMillis() - date.time
        if (ageMs > TimeUnit.DAYS.toMillis(maxAgeDays.toLong())) {
            generateAndSaveSignedPreKey()
        }
    }

    // -----------------------------------------------------------------------
    // Replenishment
    // -----------------------------------------------------------------------

    fun replenishIfNeeded(target: Int = 20) {
        val current = loadOtpkIds().size
        if (current < target / 2) {
            generateOneTimePreKeys(target - current)
        }
    }

    // -----------------------------------------------------------------------
    // SPK verification helper (used by ChatManager)
    // -----------------------------------------------------------------------

    fun verifySignedPreKey(signedPreKeyPublic: ByteArray, signature: ByteArray, signingKeyPublic: ByteArray): Boolean =
        IdentityManager.verify(signature, signedPreKeyPublic, signingKeyPublic)

    // -----------------------------------------------------------------------
    // Private: signed prekey
    // -----------------------------------------------------------------------

    private fun loadOrCreateSignedPreKey(): DHKeyPair {
        val privB64 = prefs.getString("spk_private", null)
        val pubB64  = prefs.getString("spk_public", null)
        val id      = prefs.getLong("spk_id", 0L)
        if (privB64 != null && pubB64 != null && id != 0L) {
            _signedPreKeyId = id
            val pair = DHKeyPair(
                Base64.decode(privB64, Base64.NO_WRAP),
                Base64.decode(pubB64,  Base64.NO_WRAP)
            )
            _signedPreKeyPair = pair
            return pair
        }
        return generateAndSaveSignedPreKey()
    }

    private fun generateAndSaveSignedPreKey(): DHKeyPair {
        val pair = generateDHKeyPair()
        val id   = SecureRandom().nextLong().and(Long.MAX_VALUE).coerceAtLeast(1L)
        prefs.edit()
            .putString("spk_private", Base64.encodeToString(pair.privateKeyBytes, Base64.NO_WRAP))
            .putString("spk_public",  Base64.encodeToString(pair.publicKeyBytes,  Base64.NO_WRAP))
            .putLong("spk_id", id)
            .putString("spk_date", System.currentTimeMillis().toString())
            .apply()
        _signedPreKeyPair = pair
        _signedPreKeyId   = id
        return pair
    }

    // -----------------------------------------------------------------------
    // Private: one-time prekeys
    // -----------------------------------------------------------------------

    private fun generateOneTimePreKeys(count: Int) {
        val existingIds = loadOtpkIds().toMutableList()
        repeat(count) {
            val pair = generateDHKeyPair()
            val id   = SecureRandom().nextLong().and(Long.MAX_VALUE).coerceAtLeast(1L)
            prefs.edit()
                .putString("otpk_${id}_private", Base64.encodeToString(pair.privateKeyBytes, Base64.NO_WRAP))
                .putString("otpk_${id}_public",  Base64.encodeToString(pair.publicKeyBytes,  Base64.NO_WRAP))
                .apply()
            existingIds.add(id)
        }
        saveOtpkIds(existingIds)
    }

    private fun loadOtpkIds(): List<Long> {
        val json = prefs.getString("otpk_ids", "[]") ?: "[]"
        return try {
            json.removeSurrounding("[", "]")
                .split(",")
                .filter { it.isNotBlank() }
                .map { it.trim().toLong() }
        } catch (e: Exception) { emptyList() }
    }

    private fun saveOtpkIds(ids: List<Long>) {
        prefs.edit().putString("otpk_ids", "[${ids.joinToString(",")}]").apply()
    }

    private fun loadOtpkPair(id: Long): DHKeyPair? {
        val privB64 = prefs.getString("otpk_${id}_private", null) ?: return null
        val pubB64  = prefs.getString("otpk_${id}_public", null)  ?: return null
        return DHKeyPair(Base64.decode(privB64, Base64.NO_WRAP), Base64.decode(pubB64, Base64.NO_WRAP))
    }

    private fun deleteOtpk(id: Long) {
        val ids = loadOtpkIds().toMutableList().also { it.remove(id) }
        prefs.edit()
            .remove("otpk_${id}_private")
            .remove("otpk_${id}_public")
            .apply()
        saveOtpkIds(ids)
    }

    // -----------------------------------------------------------------------
    // Factory
    // -----------------------------------------------------------------------

    companion object {
        private fun buildPrefs(context: Context): SharedPreferences {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            return EncryptedSharedPreferences.create(
                context, "sophaxchat_prekeys", masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        }
    }
}
