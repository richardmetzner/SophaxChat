package com.sophax.sophaxchat.storage

import android.content.Context
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.io.File
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encrypted-at-rest file storage for images and audio attachments.
 *
 * Algorithm: AES-256-GCM (matches iOS AES.GCM)
 * Wire format: nonce(12B) || ciphertext || tag(16B) — identical to iOS AES.GCM.SealedBox.combined
 * Directory: context.filesDir/sophax_attachments/
 * Max attachment: 512 KB
 */
class AttachmentStore(context: Context) {

    companion object {
        const val MAX_BYTES = 512 * 1024   // 512 KB
        private const val NONCE_SIZE = 12
        private const val TAG_BITS = 128   // 16 bytes
    }

    private val baseDir: File = File(context.filesDir, "sophax_attachments").also { it.mkdirs() }
    private val storageKey: ByteArray = loadOrCreateKey(context)

    init {
        // Clean up any .tmp files left behind by a previous crash (atomic rename never completed).
        baseDir.listFiles { _, name -> name.endsWith(".tmp") }?.forEach { it.delete() }
    }

    // -----------------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------------

    fun save(data: ByteArray, id: String) {
        val file = fileFor(id)
        val tmp  = File(baseDir, "$id.tmp")
        tmp.writeBytes(encrypt(data))
        tmp.renameTo(file)   // atomic on most filesystems
    }

    fun load(id: String): ByteArray {
        val encrypted = fileFor(id).readBytes()
        return decrypt(encrypted)
    }

    fun delete(id: String) = runCatching { fileFor(id).delete() }

    fun exists(id: String) = fileFor(id).exists()

    // -----------------------------------------------------------------------
    // Crypto
    // -----------------------------------------------------------------------

    private fun encrypt(plaintext: ByteArray): ByteArray {
        val nonce  = ByteArray(NONCE_SIZE).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(storageKey, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        val ciphertextAndTag = cipher.doFinal(plaintext)
        return nonce + ciphertextAndTag   // nonce(12) + ciphertext + tag(16)
    }

    private fun decrypt(data: ByteArray): ByteArray {
        val nonce          = data.sliceArray(0 until NONCE_SIZE)
        val ciphertextAndTag = data.sliceArray(NONCE_SIZE until data.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(storageKey, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        return cipher.doFinal(ciphertextAndTag)
    }

    // -----------------------------------------------------------------------
    // File helpers
    // -----------------------------------------------------------------------

    private fun fileFor(id: String): File {
        // Sanitize ID to safe filename characters (UUID chars + hyphen)
        val safe = id.filter { it.isLetterOrDigit() || it == '-' }
        return File(baseDir, safe)
    }

    // -----------------------------------------------------------------------
    // Key management
    // -----------------------------------------------------------------------

    private fun loadOrCreateKey(context: Context): ByteArray {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        val prefs = EncryptedSharedPreferences.create(
            context, "sophaxchat_attachments", masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
        val existing = prefs.getString("attachment_key", null)
        if (existing != null) return Base64.decode(existing, Base64.NO_WRAP)

        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString("attachment_key", Base64.encodeToString(key, Base64.NO_WRAP)).apply()
        return key
    }
}
