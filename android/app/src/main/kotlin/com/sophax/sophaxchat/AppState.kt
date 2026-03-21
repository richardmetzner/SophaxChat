package com.sophax.sophaxchat

import android.content.Context
import androidx.lifecycle.ViewModel
import com.sophax.sophaxchat.crypto.IdentityManager
import com.sophax.sophaxchat.protocol.KnownPeer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class AppState(context: Context) : ViewModel() {

    val identity: IdentityManager = IdentityManager(context)

    private val _isSetupComplete = MutableStateFlow(
        context.getSharedPreferences("sophaxchat_prefs", Context.MODE_PRIVATE)
            .getBoolean("setup_complete", false)
    )
    val isSetupComplete: StateFlow<Boolean> = _isSetupComplete

    private val _peers = MutableStateFlow<List<KnownPeer>>(emptyList())
    val peers: StateFlow<List<KnownPeer>> = _peers

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage

    private val prefs = context.getSharedPreferences("sophaxchat_prefs", Context.MODE_PRIVATE)

    fun createIdentity(username: String, context: Context) {
        identity.setUsername(username)
        prefs.edit().putBoolean("setup_complete", true).apply()
        _isSetupComplete.value = true
    }
}
