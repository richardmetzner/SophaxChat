package com.sophax.sophaxchat.ui.chat

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sophax.sophaxchat.AppState
import com.sophax.sophaxchat.protocol.KnownPeer

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreateGroupScreen(
    appState: AppState,
    onBack: () -> Unit,
    onGroupCreated: (groupID: String) -> Unit
) {
    val peers by appState.peers.collectAsState()

    var groupName by remember { mutableStateOf("") }
    val selected  = remember { mutableStateListOf<String>() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Group") },
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
                .fillMaxSize()
        ) {
            OutlinedTextField(
                value = groupName,
                onValueChange = { groupName = it },
                label = { Text("Group name") },
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp)
            )

            Text(
                "Select members",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(horizontal = 16.dp)
            )

            LazyColumn(modifier = Modifier.weight(1f)) {
                items(peers, key = { it.id }) { peer ->
                    PeerCheckRow(
                        peer = peer,
                        checked = peer.id in selected,
                        onToggle = {
                            if (peer.id in selected) selected.remove(peer.id)
                            else selected.add(peer.id)
                        }
                    )
                }
            }

            Button(
                onClick = {
                    val group = appState.createGroup(groupName.trim(), selected.toList())
                        ?: return@Button
                    onGroupCreated(group.id)
                },
                enabled = groupName.isNotBlank() && selected.isNotEmpty(),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp)
            ) {
                Text("Create Group (${selected.size} members)")
            }
        }
    }
}

@Composable
private fun PeerCheckRow(peer: KnownPeer, checked: Boolean, onToggle: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Checkbox(checked = checked, onCheckedChange = { onToggle() })
        Spacer(Modifier.width(8.dp))
        Column {
            Text(peer.username, style = MaterialTheme.typography.bodyLarge)
            if (peer.isOnline) {
                Text("Online", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}
