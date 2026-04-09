package com.sophax.sophaxchat.ui.chat

// FindByPeerIDScreen.kt
// SophaxChat — Android
//
// Lets the user enter a 16-character peerID and resolve it to a contact via the
// Kademlia DHT. Android port of iOS FindByPeerIDView.swift.

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.PersonSearch
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sophax.sophaxchat.AppState
import com.sophax.sophaxchat.protocol.KnownPeer
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FindByPeerIDScreen(
    appState: AppState,
    onBack: () -> Unit,
    onStartChat: (peerID: String) -> Unit
) {
    val scope = rememberCoroutineScope()

    var peerIDInput by remember { mutableStateOf("") }
    var isSearching by remember { mutableStateOf(false) }
    var foundPeer   by remember { mutableStateOf<KnownPeer?>(null) }
    var errorText   by remember { mutableStateOf<String?>(null) }

    fun search() {
        if (peerIDInput.length != 16) return
        scope.launch {
            isSearching = true
            foundPeer   = null
            errorText   = null
            try {
                foundPeer = appState.lookupPeerViaDHT(peerIDInput)
            } catch (e: Exception) {
                errorText = when {
                    appState.chatManager?.dhtEngine == null ->
                        "DHT is not running. Make sure Tor is enabled and restart the app."
                    else ->
                        "Peer not found. They may be offline or not yet reachable over the DHT network. Try again later."
                }
            }
            isSearching = false
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Find by Peer ID") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .padding(paddingValues)
                .padding(16.dp)
                .fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Input card
            Card(
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                )
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        "Peer ID",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.primary
                    )
                    OutlinedTextField(
                        value = peerIDInput,
                        onValueChange = { raw ->
                            peerIDInput = raw.lowercase().filter { it.isDigit() || it in 'a'..'f' }.take(16)
                            foundPeer  = null
                            errorText  = null
                        },
                        placeholder = { Text("16-character peer ID", fontFamily = FontFamily.Monospace) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            keyboardType   = KeyboardType.Ascii,
                            imeAction      = ImeAction.Search
                        ),
                        keyboardActions = KeyboardActions(onSearch = { search() }),
                        textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace),
                        trailingIcon = {
                            if (peerIDInput.isNotEmpty()) {
                                IconButton(onClick = { peerIDInput = ""; foundPeer = null; errorText = null }) {
                                    Icon(Icons.Default.Clear, contentDescription = "Clear")
                                }
                            }
                        },
                        supportingText = { Text("${peerIDInput.length}/16") }
                    )
                    Text(
                        "Enter the 16-character ID shown on another user's Contact Card.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                    )
                }
            }

            // Search button
            Button(
                onClick = { search() },
                enabled = peerIDInput.length == 16 && !isSearching,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            ) {
                if (isSearching) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        color = MaterialTheme.colorScheme.onPrimary,
                        strokeWidth = 2.dp
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("Searching DHT…")
                } else {
                    Icon(Icons.Default.PersonSearch, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Find via DHT")
                }
            }

            // Error
            errorText?.let { err ->
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer
                    ),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text(
                        err,
                        modifier = Modifier.padding(12.dp),
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }

            // Result
            foundPeer?.let { peer ->
                val displayName = appState.displayName(peer.id, peer.username)
                Card(
                    shape = RoundedCornerShape(12.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.5f)
                    )
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            "Found",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.secondary
                        )
                        Spacer(Modifier.height(12.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            // Avatar placeholder
                            Box(
                                modifier = Modifier
                                    .size(48.dp)
                                    .clip(CircleShape),
                                contentAlignment = Alignment.Center
                            ) {
                                Surface(
                                    color = MaterialTheme.colorScheme.primaryContainer,
                                    shape = CircleShape,
                                    modifier = Modifier.fillMaxSize()
                                ) {}
                                Text(
                                    displayName.take(1).uppercase(),
                                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 20.sp
                                )
                            }
                            Column(modifier = Modifier.weight(1f)) {
                                Text(displayName, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                                Text(
                                    peer.id,
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 12.sp,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                                )
                                peer.tcpAddress?.let { addr ->
                                    Text(
                                        addr,
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
                                        maxLines = 1
                                    )
                                }
                            }
                            Icon(
                                imageVector = Icons.Default.Check,
                                contentDescription = null,
                                tint = Color(0xFF34C759)
                            )
                        }
                        Spacer(Modifier.height(16.dp))
                        Button(
                            onClick = { onStartChat(peer.id) },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Text("Start Chat")
                        }
                    }
                }
            }
        }
    }
}
