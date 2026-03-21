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
import com.sophax.sophaxchat.ui.chat.CreateGroupScreen
import com.sophax.sophaxchat.ui.chat.GroupChatScreen
import com.sophax.sophaxchat.ui.onboarding.OnboardingScreen
import com.sophax.sophaxchat.ui.settings.SettingsScreen
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
    val peers  by appState.peers.collectAsState()
    val groups by appState.groups.collectAsState()

    NavHost(navController = navController, startDestination = "chat_list") {

        composable("chat_list") {
            ChatListScreen(
                appState = appState,
                onPeerTap     = { peerID   -> navController.navigate("chat/$peerID") },
                onGroupTap    = { groupID  -> navController.navigate("group_chat/$groupID") },
                onNewGroup    = { navController.navigate("create_group") },
                onSettingsTap = { navController.navigate("settings") }
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

        composable("group_chat/{groupID}") { backStack ->
            val groupID = backStack.arguments?.getString("groupID") ?: return@composable
            val group   = groups.firstOrNull { it.id == groupID } ?: return@composable

            GroupChatScreen(
                appState = appState,
                group    = group,
                onBack   = { navController.popBackStack() }
            )
        }

        composable("create_group") {
            CreateGroupScreen(
                appState       = appState,
                onBack         = { navController.popBackStack() },
                onGroupCreated = { groupID ->
                    navController.navigate("group_chat/$groupID") {
                        popUpTo("chat_list")
                    }
                }
            )
        }

        composable("settings") {
            SettingsScreen(
                appState = appState,
                onBack   = { navController.popBackStack() }
            )
        }
    }
}
