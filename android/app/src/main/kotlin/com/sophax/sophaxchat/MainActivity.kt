package com.sophax.sophaxchat

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.fragment.app.FragmentActivity
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.sophax.sophaxchat.ui.AppLockScreen
import com.sophax.sophaxchat.ui.SafetyNumberScreen
import com.sophax.sophaxchat.ui.chat.ChatListScreen
import com.sophax.sophaxchat.ui.chat.ChatScreen
import com.sophax.sophaxchat.ui.chat.CreateGroupScreen
import com.sophax.sophaxchat.ui.chat.GroupChatScreen
import com.sophax.sophaxchat.ui.onboarding.OnboardingScreen
import com.sophax.sophaxchat.ui.settings.BackupScreen
import com.sophax.sophaxchat.ui.settings.SettingsScreen
import com.sophax.sophaxchat.ui.theme.SophaxChatTheme

class MainActivity : FragmentActivity() {

    private val appState: AppState by viewModels()
    private var wasBackgrounded = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Start chat manager if setup already done (returning user)
        appState.startIfReady()

        // Handle launch-time deep link
        intent.data?.let { appState.handleIncomingLink(it) }

        setContent {
            SophaxChatTheme {
                val isSetupComplete by appState.isSetupComplete.collectAsState()
                val isAppLocked     by appState.isAppLocked.collectAsState()
                val pendingLink     by appState.pendingDeepLink.collectAsState()

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

                // Deep link confirmation dialog
                pendingLink?.let { link ->
                    AlertDialog(
                        onDismissRequest = { appState.dismissDeepLink() },
                        title = { Text("Add Contact?") },
                        text  = { Text("Connect to ${link.host}?\n\nOnly confirm if you trust this address.") },
                        confirmButton = {
                            TextButton(onClick = { appState.confirmDeepLink() }) { Text("Add & Connect") }
                        },
                        dismissButton = {
                            TextButton(onClick = { appState.dismissDeepLink() }) { Text("Cancel") }
                        }
                    )
                }
            }
        }
    }

    override fun onPause() {
        super.onPause()
        wasBackgrounded = true
    }

    override fun onResume() {
        super.onResume()
        // Only lock when genuinely returning from background, not when coming back
        // from the biometric prompt (which also triggers onResume).
        if (wasBackgrounded) {
            wasBackgrounded = false
            appState.lockApp()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { appState.handleIncomingLink(it) }
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
            val peerID      = backStack.arguments?.getString("peerID") ?: return@composable
            val peer              = peers.firstOrNull { it.id == peerID }
            val allMessages      by appState.messages.collectAsState()
            val msgs              = allMessages[peerID] ?: emptyList()
            val typingPeers      by appState.typingPeers.collectAsState()
            val peerAliases      by appState.peerAliases.collectAsState()
            val disappearTimers  by appState.disappearingTimers.collectAsState()

            // Populate cache from disk on first open
            LaunchedEffect(peerID) { appState.messagesFor(peerID) }

            ChatScreen(
                peerUsername      = appState.displayName(peerID, peer?.username ?: peerID),
                peerOnline        = peer?.isOnline ?: false,
                messages          = msgs,
                peerID            = peerID,
                onSend            = { body -> appState.sendMessage(peerID, body) },
                onSendImage       = { bytes -> appState.sendImage(peerID, bytes) },
                onBack            = { navController.popBackStack() },
                onMarkRead        = { appState.markAsRead(peerID) },
                isTyping          = peerID in typingPeers,
                onTyping          = { appState.sendTyping(peerID) },
                onDeleteMessage   = { msgID -> appState.deleteMessage(msgID, peerID) },
                onBlockPeer       = { appState.blockPeer(it) },
                onSafetyNumber    = { navController.navigate("safety_number/$peerID") },
                onReact           = { msgID, emoji -> appState.sendReaction(peerID, msgID, emoji) },
                onRename          = { alias -> appState.renamePeer(peerID, alias) },
                disappearingMs    = disappearTimers[peerID] ?: 0L,
                onSetDisappearing = { ms -> appState.setDisappearingTimer(peerID, ms) }
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
                onBack   = { navController.popBackStack() },
                onBackup = { navController.navigate("backup") }
            )
        }

        composable("backup") {
            BackupScreen(
                appState = appState,
                onBack   = { navController.popBackStack() }
            )
        }

        composable("safety_number/{peerID}") { backStack ->
            val peerID       = backStack.arguments?.getString("peerID") ?: return@composable
            val peer         = peers.firstOrNull { it.id == peerID }
            val safetyNumber = appState.safetyNumber(peerID) ?: ""
            SafetyNumberScreen(
                peerID       = peerID,
                peerUsername = peer?.username ?: peerID,
                safetyNumber = safetyNumber,
                appState     = appState,
                onBack       = { navController.popBackStack() }
            )
        }
    }
}
