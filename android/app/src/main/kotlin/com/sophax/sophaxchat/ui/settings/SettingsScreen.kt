package com.sophax.sophaxchat.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sophax.sophaxchat.AppState
import com.sophax.sophaxchat.network.TorState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    appState: AppState,
    onBack: () -> Unit,
    onBackup: () -> Unit = {},
    onDuressPin: () -> Unit = {},
    onLinkedDevices: () -> Unit = {}
) {
    val username     by appState.username.collectAsState()
    val tcpEnabled   by appState.tcpEnabled.collectAsState()
    val blockedPeers by appState.blockedPeers.collectAsState()
    val torState     by appState.torManager.state.collectAsState()
    val torProgress  by appState.torManager.bootstrapProgress.collectAsState()

    var usernameEdit by remember(username) { mutableStateOf(username) }
    var showQR       by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // ----------------------------------------------------------------
            // Identity
            // ----------------------------------------------------------------
            SectionLabel("Identity")

            OutlinedTextField(
                value = usernameEdit,
                onValueChange = { usernameEdit = it },
                label = { Text("Username") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                onClick = { appState.changeUsername(usernameEdit) },
                enabled = usernameEdit.isNotBlank() && usernameEdit != username,
                modifier = Modifier.fillMaxWidth()
            ) { Text("Save Username") }

            HorizontalDivider()

            // ----------------------------------------------------------------
            // Network
            // ----------------------------------------------------------------
            SectionLabel("Network")

            // Tor status card
            when (val ts = torState) {
                is TorState.Ready -> Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.primaryContainer
                    )
                ) {
                    Row(
                        modifier = Modifier.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Default.Security, contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary
                        )
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text("Anonymous & ready",
                                style = MaterialTheme.typography.titleSmall)
                            Text("Tor is running — share your address to receive messages",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                is TorState.Starting -> Card {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp), strokeWidth = 2.dp
                            )
                            Spacer(Modifier.width(12.dp))
                            Text("Connecting to Tor…",
                                style = MaterialTheme.typography.titleSmall)
                            Spacer(Modifier.weight(1f))
                            Text("$torProgress%",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Spacer(Modifier.height(8.dp))
                        LinearProgressIndicator(
                            progress = { torProgress / 100f },
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
                is TorState.Failed -> Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer
                    )
                ) {
                    Row(
                        modifier = Modifier.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Default.Warning, contentDescription = null,
                            tint = MaterialTheme.colorScheme.error)
                        Spacer(Modifier.width(12.dp))
                        Text("Tor unavailable: ${ts.reason}",
                            style = MaterialTheme.typography.bodySmall)
                    }
                }
                else -> {}
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Connect Globally (TCP / Tor)", style = MaterialTheme.typography.bodyLarge)
                Switch(checked = tcpEnabled, onCheckedChange = { appState.setTcpEnabled(it) })
            }

            OutlinedButton(
                onClick = { showQR = true },
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.QrCode, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("My QR Code")
            }

            HorizontalDivider()

            // ----------------------------------------------------------------
            // Security
            // ----------------------------------------------------------------
            SectionLabel("Security")

            var appLockEnabled by remember { mutableStateOf(appState.appLockEnabled) }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("App Lock", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "Require biometrics or PIN on open",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                    )
                }
                Switch(
                    checked = appLockEnabled,
                    onCheckedChange = {
                        appLockEnabled = it
                        appState.setAppLockEnabled(it)
                    }
                )
            }

            // Linked Devices
            OutlinedButton(
                onClick = onLinkedDevices,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Linked Devices")
            }

            // Duress PIN
            OutlinedButton(
                onClick = onDuressPin,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Duress PIN")
            }

            OutlinedButton(
                onClick = onBackup,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Backup & Restore")
            }

            HorizontalDivider()

            // ----------------------------------------------------------------
            // Blocked users
            // ----------------------------------------------------------------
            SectionLabel("Blocked Users")

            if (blockedPeers.isEmpty()) {
                Text(
                    "No blocked users.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                )
            } else {
                blockedPeers.forEach { peerID ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(peerID, style = MaterialTheme.typography.bodyMedium)
                        TextButton(onClick = { appState.unblockPeer(peerID) }) {
                            Text("Unblock")
                        }
                    }
                }
            }

            HorizontalDivider()

            // ----------------------------------------------------------------
            // About
            // ----------------------------------------------------------------
            SectionLabel("About")
            Text("SophaxChat", style = MaterialTheme.typography.bodyLarge)
            Text(
                "End-to-end encrypted, serverless, anonymous P2P messaging.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
            )
            Text(
                "Open source · github.com/richardmetzner/SophaxChat",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary
            )
        }

        if (showQR) {
            ContactQRSheet(
                contactUrl = appState.myContactUrl,
                onDismiss = { showQR = false }
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary
    )
}
