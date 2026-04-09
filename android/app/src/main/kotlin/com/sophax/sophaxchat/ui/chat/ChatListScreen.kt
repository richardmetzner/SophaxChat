package com.sophax.sophaxchat.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sophax.sophaxchat.AppState
import com.sophax.sophaxchat.crypto.GroupInfo
import com.sophax.sophaxchat.protocol.KnownPeer

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ChatListScreen(
    appState: AppState,
    onPeerTap: (String) -> Unit = {},
    onGroupTap: (String) -> Unit = {},
    onNewGroup: () -> Unit = {},
    onSettingsTap: () -> Unit = {},
    onFindByPeerID: () -> Unit = {}
) {
    val peers        by appState.peers.collectAsState()
    val groups       by appState.groups.collectAsState()
    val unreadCounts by appState.unreadCounts.collectAsState()
    val peerAliases  by appState.peerAliases.collectAsState()
    val myPeerID     = appState.myPeerID

    var groupToDelete by remember { mutableStateOf<GroupInfo?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text("SophaxChat", fontWeight = FontWeight.Bold, fontSize = 22.sp)
                },
                actions = {
                    IconButton(onClick = onFindByPeerID) {
                        Icon(Icons.Default.Person, contentDescription = "Find by Peer ID")
                    }
                    IconButton(onClick = onNewGroup) {
                        Icon(Icons.Default.Add, contentDescription = "New Group")
                    }
                    IconButton(onClick = onSettingsTap) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                }
            )
        }
    ) { paddingValues ->
        if (peers.isEmpty() && groups.isEmpty()) {
            EmptyState(modifier = Modifier.padding(paddingValues))
        } else {
            LazyColumn(
                modifier = Modifier.padding(paddingValues),
                contentPadding = PaddingValues(vertical = 8.dp)
            ) {
                if (groups.isNotEmpty()) {
                    item {
                        SectionHeader("Groups")
                    }
                    items(groups, key = { "g_${it.id}" }) { group ->
                        GroupRow(
                            group   = group,
                            unread  = unreadCounts[group.conversationID] ?: 0,
                            onClick = { onGroupTap(group.id) },
                            onLongClick = if (group.creatorID == myPeerID) {
                                { groupToDelete = group }
                            } else null
                        )
                    }
                    if (peers.isNotEmpty()) {
                        item { SectionHeader("Direct Messages") }
                    }
                }
                items(peers, key = { it.id }) { peer ->
                    PeerRow(peer, displayName = peerAliases[peer.id]?.takeIf { it.isNotBlank() } ?: peer.username, unread = unreadCounts[peer.id] ?: 0, onClick = { onPeerTap(peer.id) })
                }
            }
        }
    }

    groupToDelete?.let { group ->
        AlertDialog(
            onDismissRequest = { groupToDelete = null },
            title   = { Text("Delete Group") },
            text    = { Text("Delete \"${group.name}\" for all members? This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    appState.deleteGroup(group)
                    groupToDelete = null
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { groupToDelete = null }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)
    )
}

@Composable
private fun EmptyState(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(horizontal = 40.dp)
        ) {
            Text(
                "((•))", fontSize = 48.sp,
                color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.25f)
            )
            Text(
                "Looking for nearby devices…",
                style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.5f),
                textAlign = TextAlign.Center
            )
            Text(
                "Make sure both devices have the app open and are within Bluetooth/WiFi range.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.35f),
                textAlign = TextAlign.Center
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GroupRow(group: GroupInfo, unread: Int, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    val initial = group.name.firstOrNull()?.uppercaseChar()?.toString() ?: "G"

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(CircleShape)
                .background(Color(0xFF34C759).copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center
        ) {
            Text(initial, fontWeight = FontWeight.Bold, fontSize = 20.sp, color = Color(0xFF34C759))
        }

        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(group.name, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Text(
                "${group.memberIDs.size} members",
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
            )
        }

        if (unread > 0) {
            Badge { Text("$unread") }
        }
    }

    HorizontalDivider(modifier = Modifier.padding(start = 76.dp), thickness = 0.5.dp)
}

@Composable
private fun PeerRow(peer: KnownPeer, displayName: String, unread: Int, onClick: () -> Unit) {
    val initial = displayName.firstOrNull()?.uppercaseChar()?.toString() ?: "?"

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(CircleShape)
                .background(Color(0xFF007AFF).copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center
        ) {
            Text(initial, fontWeight = FontWeight.Bold, fontSize = 20.sp, color = Color(0xFF007AFF))
        }

        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(displayName, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Text(
                if (peer.isOnline) "Online" else "Last seen recently",
                fontSize = 13.sp,
                color = if (peer.isOnline) Color(0xFF34C759)
                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
            )
        }

        if (unread > 0) {
            Badge { Text("$unread") }
        } else if (peer.isOnline) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF34C759))
            )
        }
    }

    HorizontalDivider(modifier = Modifier.padding(start = 76.dp), thickness = 0.5.dp)
}
