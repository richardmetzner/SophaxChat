package com.sophax.sophaxchat

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import com.sophax.sophaxchat.ui.chat.ChatListScreen
import com.sophax.sophaxchat.ui.onboarding.OnboardingScreen
import com.sophax.sophaxchat.ui.theme.SophaxChatTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SophaxChatTheme {
                val appState = remember { AppState(applicationContext) }
                val isSetupComplete by appState.isSetupComplete.collectAsState()

                if (isSetupComplete) {
                    ChatListScreen(appState)
                } else {
                    OnboardingScreen(onComplete = { username ->
                        appState.createIdentity(username, applicationContext)
                    })
                }
            }
        }
    }
}
