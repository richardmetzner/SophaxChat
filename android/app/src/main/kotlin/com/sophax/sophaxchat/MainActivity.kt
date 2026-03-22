package com.sophax.sophaxchat

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.fragment.app.FragmentActivity
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.sophax.sophaxchat.ui.AppLockScreen
import com.sophax.sophaxchat.ui.chat.ChatListScreen
import com.sophax.sophaxchat.ui.chat.ChatScreen
import com.sophax.sophaxchat.ui.chat.CreateGroupScreen
import com.sophax.sophaxchat.ui.chat.GroupChatScreen
import com.sophax.sophaxchat.ui.onboarding.OnboardingScreen
import com.sophax.sophaxchat.ui.settings.SettingsScreen
import com.sophax.sophaxchat.ui.theme.SophaxChatTheme

class MainActivity : FragmentActivity() {

    private lateinit var appState: AppState

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        appState = AppState(applicationContext)
        enableEdgeToEdge()
        setContent {
            SophaxChatTheme {
                val isSetupComplete by appState.isSetupComplete.collectAsState()
                val isAppLocked     by appState.isAppLocked.collectAsState()

                LaunchedEffect(isSetupComplete) {
                    appState.startIfReady()
                }

                Box(modifier = Modifier.fillMaxSize()) {
                    if (!isSetupComplete) {
                        OnboardingScreen(onComplete = { username ->
                            appState.createIdentity(username)
                        })
                    } else {
                        AppNavigation(appState)
                    }

                    // App Lock overlay — rendered on top of everything when locked
                    if (isAppLocked) {
                        AppLockScreen(onUnlocked = { appState.unlockApp() })
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Lock the app every time it comes to the foreground (if app lock is enabled)
        appState.lockApp()
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
                onBack       = { navController.popBackStack() },
                onMarkRead   = { appState.markAsRead(peerID) }
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
