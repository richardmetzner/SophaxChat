package com.sophax.sophaxchat.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sophax.sophaxchat.AppState
import com.sophax.sophaxchat.protocol.KnownPeer

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatListScreen(appState: AppState) {
    val peers by appState.peers.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "SophaxChat",
                        fontWeight = FontWeight.Bold,
                        fontSize = 22.sp
                    )
                },
                actions = {
                    IconButton(onClick = { /* TODO: settings */ }) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                    IconButton(onClick = { /* TODO: identity */ }) {
                        Icon(Icons.Default.Person, contentDescription = "Identity")
                    }
                }
            )
        }
    ) { paddingValues ->
        if (peers.isEmpty()) {
            EmptyState(modifier = Modifier.padding(paddingValues))
        } else {
            LazyColumn(
                modifier = Modifier.padding(paddingValues),
                contentPadding = PaddingValues(vertical = 8.dp)
            ) {
                items(peers, key = { it.id }) { peer ->
                    PeerRow(peer)
                }
            }
        }
    }
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
            Text("((•))", fontSize = 48.sp, color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.25f))
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

@Composable
private fun PeerRow(peer: KnownPeer) {
    val initial = peer.username.firstOrNull()?.uppercaseChar()?.toString() ?: "?"
    val avatarColor = Color(0xFF007AFF).copy(alpha = 0.12f)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Avatar
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(CircleShape)
                .background(avatarColor),
            contentAlignment = Alignment.Center
        ) {
            Text(initial, fontWeight = FontWeight.Bold, fontSize = 20.sp, color = Color(0xFF007AFF))
        }

        Spacer(Modifier.width(12.dp))

        Column {
            Text(peer.username, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Text(
                if (peer.isOnline) "Online" else "Last seen recently",
                fontSize = 13.sp,
                color = if (peer.isOnline) Color(0xFF34C759) else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
            )
        }

        Spacer(Modifier.weight(1f))

        if (peer.isOnline) {
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
