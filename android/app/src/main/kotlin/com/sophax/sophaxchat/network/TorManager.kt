package com.sophax.sophaxchat.network

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import com.sophax.sophaxchat.crypto.HiddenServiceKeyWriter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.torproject.android.service.TorService
import org.torproject.android.service.util.Prefs
import java.io.File

// TorManager.kt
// SophaxChat — Android
//
// Manages embedded Tor lifecycle. No Orbot required.
// Provides a local SOCKS5 proxy on 127.0.0.1:9050 once ready.
// Configures a v3 hidden service whose address equals OnionAddress.from(ed25519PublicKey)
// when started after configureHiddenService() is called.

sealed class TorState {
    object Stopped  : TorState()
    object Starting : TorState()
    object Ready    : TorState()
    data class Failed(val reason: String) : TorState()
}

class TorManager(private val context: Context) {

    companion object {
        const val SOCKS_HOST  = "127.0.0.1"
        const val SOCKS_PORT  = 9050
        const val SOCKS_PROXY = "$SOCKS_HOST:$SOCKS_PORT"
        const val HS_PORT     = 25519
    }

    private val _state = MutableStateFlow<TorState>(TorState.Stopped)
    val state: StateFlow<TorState> = _state

    private val _bootstrapProgress = MutableStateFlow(0)
    val bootstrapProgress: StateFlow<Int> = _bootstrapProgress

    /** Hostname of our v3 hidden service (without port), set once Tor reaches 100% bootstrap.
     *  Equals `OnionAddress.from(ed25519PublicKey)` when started after [configureHiddenService]. */
    private val _hiddenServiceHostname = MutableStateFlow<String?>(null)
    val hiddenServiceHostname: StateFlow<String?> = _hiddenServiceHostname

    private var receiverRegistered = false

    // tor-android stores its data under context.filesDir/tor/
    private val torDataDir: File get() = File(context.filesDir, "tor")
    private val hiddenServiceDir: File get() = File(torDataDir, "hidden_service")

    // Receives Tor log lines broadcast by TorService.
    // Bootstrap progress is parsed from lines like "Bootstrapped 25% (..."
    private val logReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val log = intent.getStringExtra(TorService.EXTRA_STATUS)
                ?: intent.getStringExtra("EXTRA_LOG")
                ?: return
            val progress = parseProgress(log)
            if (progress >= 0) {
                _bootstrapProgress.value = progress
                if (progress >= 100) {
                    readHiddenServiceHostname()
                    _state.value = TorState.Ready
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Hidden service configuration

    /**
     * Writes deterministic hidden service key files from the user's Ed25519 identity seed,
     * and updates the Tor torrc to configure the hidden service.
     * Call before [start] — safe to call repeatedly (idempotent).
     *
     * @param ed25519PrivateKeySeed  32-byte Ed25519 seed (first half of the stored 64-byte key)
     */
    fun configureHiddenService(ed25519PrivateKeySeed: ByteArray) {
        // Write key files: hs_ed25519_secret_key + hs_ed25519_public_key
        HiddenServiceKeyWriter.write(hiddenServiceDir, ed25519PrivateKeySeed)

        // Write hidden service torrc lines.
        // TorService (tor-android) reads <filesDir>/tor/torrc — we append our HS config
        // if not already present. TorService preserves existing torrc content on restart.
        writeTorrcHiddenServiceLines()
    }

    // -------------------------------------------------------------------------
    // Lifecycle

    fun start() {
        if (_state.value !is TorState.Stopped) return
        _state.value = TorState.Starting
        _bootstrapProgress.value = 0
        _hiddenServiceHostname.value = null

        Prefs.setContext(context)

        if (!receiverRegistered) {
            ContextCompat.registerReceiver(
                context, logReceiver,
                IntentFilter(TorService.LOCAL_ACTION_LOG),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            receiverRegistered = true
        }

        val intent = Intent(context, TorService::class.java)
        intent.action = TorService.ACTION_START
        context.startService(intent)
    }

    fun stop() {
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(logReceiver) }
            receiverRegistered = false
        }
        context.stopService(Intent(context, TorService::class.java))
        _state.value = TorState.Stopped
        _bootstrapProgress.value = 0
    }

    // -------------------------------------------------------------------------
    // Private helpers

    /** Reads the .onion hostname from the hidden service directory once Tor has written it. */
    private fun readHiddenServiceHostname() {
        val hostnameFile = File(hiddenServiceDir, "hostname")
        if (!hostnameFile.exists()) return
        val raw = hostnameFile.readText().trim()
        if (raw.endsWith(".onion") && raw.length == 62) {
            _hiddenServiceHostname.value = raw
        }
    }

    /**
     * Appends hidden service configuration lines to the Tor torrc file if not already present.
     * tor-android (TorService) reads this file and preserves user-added lines.
     */
    private fun writeTorrcHiddenServiceLines() {
        torDataDir.mkdirs()
        val torrc = File(torDataDir, "torrc")

        val hsDirLine  = "HiddenServiceDir ${hiddenServiceDir.absolutePath}"
        val hsPortLine = "HiddenServicePort $HS_PORT 127.0.0.1:$HS_PORT"
        val hsVerLine  = "HiddenServiceVersion 3"

        val existing = if (torrc.exists()) torrc.readText() else ""
        if (hsDirLine in existing) return  // already configured

        val linesToAdd = buildString {
            if (existing.isNotEmpty() && !existing.endsWith("\n")) appendLine()
            appendLine(hsDirLine)
            appendLine(hsPortLine)
            appendLine(hsVerLine)
        }
        torrc.appendText(linesToAdd)
    }

    private fun parseProgress(log: String): Int {
        val match = Regex("Bootstrapped (\\d+)%").find(log) ?: return -1
        return match.groupValues[1].toIntOrNull() ?: -1
    }
}
