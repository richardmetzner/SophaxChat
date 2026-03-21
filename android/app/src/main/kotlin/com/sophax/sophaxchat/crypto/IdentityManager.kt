package com.sophax.sophaxchat.crypto

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.generators.X25519KeyPairGenerator
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.X25519KeyGenerationParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.MessageDigest
import java.security.SecureRandom

// ---------------------------------------------------------------------------
// Public identity — what we share with peers
// ---------------------------------------------------------------------------

data class PublicIdentity(
    val username: String,
    val signingKeyPublic: ByteArray,   // Ed25519, 32 bytes
    val dhKeyPublic: ByteArray,        // X25519, 32 bytes
    val safetyNumber: String,
) {
    /** Deterministic peer ID — matches iOS: hex(SHA256(signing || dh))[0..15] */
    val peerID: String get() {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(signingKeyPublic)
        digest.update(dhKeyPublic)
        return digest.digest().toHex().take(16)
    }

    override fun equals(other: Any?) = other is PublicIdentity && peerID == other.peerID
    override fun hashCode() = peerID.hashCode()
}

// ---------------------------------------------------------------------------
// IdentityManager — generates, stores, and uses identity keys
// ---------------------------------------------------------------------------

class IdentityManager(context: Context) {

    private val prefs = buildPrefs(context)

    // Lazily-loaded key pairs
    private val signingKeyPair: SigningKeyPair by lazy { loadOrCreateSigning() }
    private val dhKeyPair: DHKeyPair by lazy { loadOrCreateDH() }

    val publicIdentity: PublicIdentity get() = PublicIdentity(
        username     = prefs.getString(KEY_USERNAME, "anonymous") ?: "anonymous",
        signingKeyPublic = signingKeyPair.publicKeyBytes,
        dhKeyPublic  = dhKeyPair.publicKeyBytes,
        safetyNumber = selfSafetyNumber(),
    )

    val dhIdentityKeyPair: DHKeyPair get() = dhKeyPair
    val signingKeyPairInternal: SigningKeyPair get() = signingKeyPair
    val username: String get() = prefs.getString(KEY_USERNAME, "anonymous") ?: "anonymous"

    // -----------------------------------------------------------------------
    // Username
    // -----------------------------------------------------------------------

    fun setUsername(name: String) {
        require(name.isNotBlank() && name.length <= 64) { "Username must be 1–64 characters" }
        prefs.edit().putString(KEY_USERNAME, name.trim()).apply()
    }

    // -----------------------------------------------------------------------
    // Signing
    // -----------------------------------------------------------------------

    fun sign(data: ByteArray): ByteArray {
        val signer = Ed25519Signer()
        val privKey = Ed25519PrivateKeyParameters(signingKeyPair.privateKeyBytes)
        signer.init(true, privKey)
        signer.update(data, 0, data.size)
        return signer.generateSignature()
    }

    // -----------------------------------------------------------------------
    // Static verify
    // -----------------------------------------------------------------------

    companion object {
        fun verify(signature: ByteArray, data: ByteArray, signingKeyPublic: ByteArray): Boolean {
            return try {
                val verifier = Ed25519Signer()
                val pubKey = Ed25519PublicKeyParameters(signingKeyPublic)
                verifier.init(false, pubKey)
                verifier.update(data, 0, data.size)
                verifier.verifySignature(signature)
            } catch (e: Exception) {
                false
            }
        }

        /** Safety number for a verified pair — matches iOS formula */
        fun safetyNumber(
            mySigningKey: ByteArray, theirSigningKey: ByteArray,
            myDHKey: ByteArray,      theirDHKey: ByteArray
        ): String {
            val digest = MessageDigest.getInstance("SHA-512")
            digest.update(mySigningKey)
            digest.update(theirSigningKey)
            digest.update(myDHKey)
            digest.update(theirDHKey)
            val hash = digest.digest()
            // 12 groups of 5 decimal digits (same as iOS)
            return (0 until 12).joinToString(" ") { i ->
                val offset = i * 5
                val num = (hash[offset].toLong() and 0xFF) * 256 + (hash[offset + 1].toLong() and 0xFF)
                "%05d".format(num % 100000)
            }
        }

        private fun buildPrefs(context: Context): android.content.SharedPreferences {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            return EncryptedSharedPreferences.create(
                context,
                "sophaxchat_identity",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        }

        private const val KEY_SIGNING_PRIVATE = "signing_private"
        private const val KEY_SIGNING_PUBLIC  = "signing_public"
        private const val KEY_DH_PRIVATE      = "dh_private"
        private const val KEY_DH_PUBLIC       = "dh_public"
        private const val KEY_USERNAME        = "username"
    }

    // -----------------------------------------------------------------------
    // Key loading / generation
    // -----------------------------------------------------------------------

    private fun loadOrCreateSigning(): SigningKeyPair {
        val privB64 = prefs.getString(KEY_SIGNING_PRIVATE, null)
        val pubB64  = prefs.getString(KEY_SIGNING_PUBLIC, null)
        if (privB64 != null && pubB64 != null) {
            return SigningKeyPair(
                android.util.Base64.decode(privB64, android.util.Base64.NO_WRAP),
                android.util.Base64.decode(pubB64,  android.util.Base64.NO_WRAP)
            )
        }
        return generateSigningKeyPair().also { pair ->
            prefs.edit()
                .putString(KEY_SIGNING_PRIVATE, android.util.Base64.encodeToString(pair.privateKeyBytes, android.util.Base64.NO_WRAP))
                .putString(KEY_SIGNING_PUBLIC,  android.util.Base64.encodeToString(pair.publicKeyBytes,  android.util.Base64.NO_WRAP))
                .apply()
        }
    }

    private fun loadOrCreateDH(): DHKeyPair {
        val privB64 = prefs.getString(KEY_DH_PRIVATE, null)
        val pubB64  = prefs.getString(KEY_DH_PUBLIC, null)
        if (privB64 != null && pubB64 != null) {
            return DHKeyPair(
                android.util.Base64.decode(privB64, android.util.Base64.NO_WRAP),
                android.util.Base64.decode(pubB64,  android.util.Base64.NO_WRAP)
            )
        }
        return generateDHKeyPair().also { pair ->
            prefs.edit()
                .putString(KEY_DH_PRIVATE, android.util.Base64.encodeToString(pair.privateKeyBytes, android.util.Base64.NO_WRAP))
                .putString(KEY_DH_PUBLIC,  android.util.Base64.encodeToString(pair.publicKeyBytes,  android.util.Base64.NO_WRAP))
                .apply()
        }
    }

    private fun selfSafetyNumber(): String {
        // Self safety number — SHA-512 of own keys (placeholder; real one is per-contact)
        val digest = MessageDigest.getInstance("SHA-512")
        digest.update(signingKeyPair.publicKeyBytes)
        digest.update(dhKeyPair.publicKeyBytes)
        val hash = digest.digest()
        return (0 until 12).joinToString(" ") { i ->
            val offset = i * 5
            val num = (hash[offset].toLong() and 0xFF) * 256 + (hash[offset + 1].toLong() and 0xFF)
            "%05d".format(num % 100000)
        }
    }
}

// ---------------------------------------------------------------------------
// Key generation helpers (top-level for reuse in PreKeyManager)
// ---------------------------------------------------------------------------

fun generateSigningKeyPair(): SigningKeyPair {
    val gen = Ed25519KeyPairGenerator()
    gen.init(Ed25519KeyGenerationParameters(SecureRandom()))
    val kp = gen.generateKeyPair()
    val priv = (kp.private as Ed25519PrivateKeyParameters).encoded   // 32-byte seed
    val pub  = (kp.public  as Ed25519PublicKeyParameters).encoded    // 32 bytes
    // Expand to 64-byte format (seed || public) so BC can reconstruct for signing
    return SigningKeyPair(priv + pub, pub)
}

fun generateDHKeyPair(): DHKeyPair {
    val gen = X25519KeyPairGenerator()
    gen.init(X25519KeyGenerationParameters(SecureRandom()))
    val kp = gen.generateKeyPair()
    val priv = (kp.private as X25519PrivateKeyParameters).encoded   // 32 bytes
    val pub  = (kp.public  as X25519PublicKeyParameters).encoded    // 32 bytes
    return DHKeyPair(priv, pub)
}

/** Raw X25519 ECDH: returns 32-byte shared secret. */
fun x25519(privateKeyBytes: ByteArray, publicKeyBytes: ByteArray): ByteArray {
    val priv = X25519PrivateKeyParameters(privateKeyBytes)
    val pub  = X25519PublicKeyParameters(publicKeyBytes)
    val agreement = org.bouncycastle.crypto.agreement.X25519Agreement()
    agreement.init(priv)
    val result = ByteArray(32)
    agreement.calculateAgreement(pub, result, 0)
    return result
}
