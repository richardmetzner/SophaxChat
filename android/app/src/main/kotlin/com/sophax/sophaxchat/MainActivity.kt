package com.sophax.sophaxchat

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.sophax.sophaxchat.ui.chat.ChatListScreen
import com.sophax.sophaxchat.ui.chat.ChatScreen
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

                LaunchedEffect(isSetupComplete) {
                    appState.startIfReady()
                }

                if (!isSetupComplete) {
                    OnboardingScreen(onComplete = { username ->
                        appState.createIdentity(username)
                    })
                } else {
                    AppNavigation(appState)
                }
            }
        }
    }
}

@Composable
private fun AppNavigation(appState: AppState) {
    val navController = rememberNavController()
    val peers by appState.peers.collectAsState()

    NavHost(navController = navController, startDestination = "chat_list") {
        composable("chat_list") {
            ChatListScreen(
                appState = appState,
                onPeerTap = { peerID -> navController.navigate("chat/$peerID") }
            )
        }
        composable("chat/{peerID}") { backStack ->
            val peerID = backStack.arguments?.getString("peerID") ?: return@composable
            val peer   = peers.firstOrNull { it.id == peerID }
            val msgs   by remember(peerID) { derivedStateOf { appState.messagesFor(peerID) } }

            ChatScreen(
                peerUsername = peer?.username ?: peerID,
                peerOnline   = peer?.isOnline ?: false,
                messages     = msgs,
                onSend       = { body -> appState.sendMessage(peerID, body) },
                onBack       = { navController.popBackStack() }
            )
        }
    }
}
