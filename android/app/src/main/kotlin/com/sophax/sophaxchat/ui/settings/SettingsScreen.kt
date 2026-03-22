package com.sophax.sophaxchat.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sophax.sophaxchat.AppState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(appState: AppState, onBack: () -> Unit) {
    val username    by appState.username.collectAsState()
    val tcpEnabled  by appState.tcpEnabled.collectAsState()
    val socksProxy  by appState.socksProxy.collectAsState()
    val blockedPeers by appState.blockedPeers.collectAsState()

    var usernameEdit by remember(username) { mutableStateOf(username) }
    var proxyEdit    by remember(socksProxy) { mutableStateOf(socksProxy) }

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

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Connect Globally (TCP / Tor)", style = MaterialTheme.typography.bodyLarge)
                Switch(checked = tcpEnabled, onCheckedChange = { appState.setTcpEnabled(it) })
            }

            if (tcpEnabled) {
                OutlinedTextField(
                    value = proxyEdit,
                    onValueChange = { proxyEdit = it },
                    label = { Text("SOCKS5 Proxy (host:port)") },
                    placeholder = { Text("127.0.0.1:9050") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    onClick = { appState.setSocksProxy(proxyEdit) },
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Apply Proxy") }
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
                "Open source · github.com/sophaxtechnologies/SophaxChat",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary
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
