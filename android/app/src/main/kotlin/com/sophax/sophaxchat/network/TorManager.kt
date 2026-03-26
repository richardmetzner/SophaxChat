package com.sophax.sophaxchat.network

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.torproject.android.service.TorService
import org.torproject.android.service.util.Prefs

// TorManager.kt
// SophaxChat — Android
//
// Manages embedded Tor lifecycle. No Orbot required.
// Provides a local SOCKS5 proxy on 127.0.0.1:9050 once ready.

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
    }

    private val _state = MutableStateFlow<TorState>(TorState.Stopped)
    val state: StateFlow<TorState> = _state

    private val _bootstrapProgress = MutableStateFlow(0)
    val bootstrapProgress: StateFlow<Int> = _bootstrapProgress

    private var receiverRegistered = false

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
                if (progress >= 100) _state.value = TorState.Ready
            }
        }
    }

    fun start() {
        if (_state.value !is TorState.Stopped) return
        _state.value = TorState.Starting
        _bootstrapProgress.value = 0

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

    private fun parseProgress(log: String): Int {
        val match = Regex("Bootstrapped (\\d+)%").find(log) ?: return -1
        return match.groupValues[1].toIntOrNull() ?: -1
    }
}
