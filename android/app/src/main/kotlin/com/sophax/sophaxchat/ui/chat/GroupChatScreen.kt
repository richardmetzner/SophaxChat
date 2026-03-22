package com.sophax.sophaxchat.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sophax.sophaxchat.AppState
import com.sophax.sophaxchat.crypto.GroupInfo
import com.sophax.sophaxchat.storage.MessageDirection
import com.sophax.sophaxchat.storage.StoredMessage

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupChatScreen(
    appState: AppState,
    group: GroupInfo,
    onBack: () -> Unit
) {
    val messages    by remember(group.id) {
        derivedStateOf { appState.messagesFor(group.conversationID) }
    }
    val peers       by appState.peers.collectAsState()
    val typingPeers by appState.typingPeers.collectAsState()
    val typingNames = typingPeers
        .filter { it in group.memberIDs }
        .mapNotNull { id -> peers.firstOrNull { it.id == id }?.username }

    var inputText     by remember { mutableStateOf("") }
    var replyTo       by remember { mutableStateOf<StoredMessage?>(null) }
    var showMemberSheet by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()

    // Mark all messages read when this screen opens
    LaunchedEffect(Unit) { appState.markAsRead(group.conversationID) }

    // Send typing to each group member
    LaunchedEffect(inputText) {
        if (inputText.isNotEmpty()) {
            kotlinx.coroutines.delay(500)
            group.memberIDs.filter { it != appState.myPeerID }
                .forEach { appState.sendTyping(it) }
        }
    }

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.scrollToItem(messages.size - 1)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(group.name, fontWeight = FontWeight.Bold, fontSize = 17.sp)
                        if (typingNames.isNotEmpty()) {
                            Text(
                                "${typingNames.joinToString(", ")} typing…",
                                fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.primary
                            )
                        } else {
                            Text(
                                "${group.memberIDs.size} members",
                                fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { showMemberSheet = true }) {
                        Icon(Icons.Default.Info, contentDescription = "Group Info")
                    }
                }
            )
        },
        bottomBar = {
            GroupInputBar(
                text         = inputText,
                replyTo      = replyTo,
                onClearReply = { replyTo = null },
                onTextChange = { inputText = it },
                onSend = {
                    if (inputText.isNotBlank()) {
                        val body = if (replyTo != null)
                            "> ${replyTo!!.body.take(60)}\n${inputText.trim()}"
                        else inputText.trim()
                        appState.sendGroupMessage(body, group)
                        inputText = ""
                        replyTo = null
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(vertical = 8.dp)
        ) {
            items(messages, key = { it.id }) { msg ->
                val senderName = if (msg.direction == MessageDirection.sent.name) {
                    "You"
                } else {
                    peers.firstOrNull { it.id == msg.peerID }?.username ?: msg.peerID.take(8)
                }
                GroupMessageBubble(
                    message    = msg,
                    senderName = senderName,
                    onDelete   = { appState.deleteMessage(msg.id, group.conversationID) },
                    onBlock    = if (msg.direction != MessageDirection.sent.name) {
                        { appState.blockPeer(msg.peerID) }
                    } else null,
                    onReply    = { replyTo = msg }
                )
            }
        }
    }

    if (showMemberSheet) {
        GroupMemberSheet(
            group = group,
            peers = peers.filter { it.id in group.memberIDs },
            myPeerID = appState.myPeerID,
            onLeave = {
                appState.leaveGroup(group)
                onBack()
            },
            onDismiss = { showMemberSheet = false }
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GroupMessageBubble(
    message: StoredMessage,
    senderName: String,
    onDelete: () -> Unit = {},
    onBlock: (() -> Unit)? = null,
    onReply: () -> Unit = {}
) {
    val isMe = message.direction == MessageDirection.sent.name
    val context = LocalContext.current
    var showMenu by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 3.dp),
        horizontalArrangement = if (isMe) Arrangement.End else Arrangement.Start
    ) {
        Column(
            modifier = Modifier.widthIn(max = 280.dp),
            horizontalAlignment = if (isMe) Alignment.End else Alignment.Start
        ) {
            if (!isMe) {
                Text(
                    senderName,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 4.dp, bottom = 2.dp)
                )
            }
            Box {
                Box(
                    modifier = Modifier
                        .clip(
                            RoundedCornerShape(
                                topStart = 16.dp, topEnd = 16.dp,
                                bottomStart = if (isMe) 16.dp else 4.dp,
                                bottomEnd = if (isMe) 4.dp else 16.dp
                            )
                        )
                        .background(
                            if (isMe) Color(0xFF007AFF)
                            else MaterialTheme.colorScheme.surfaceVariant
                        )
                        .combinedClickable(
                            onClick = {},
                            onLongClick = { showMenu = true }
                        )
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Text(
                        message.body,
                        color = if (isMe) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 15.sp
                    )
                }
                DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("Reply") },
                        onClick = { showMenu = false; onReply() }
                    )
                    DropdownMenuItem(
                        text = { Text("Copy") },
                        onClick = {
                            showMenu = false
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("message", message.body))
                        }
                    )
                    DropdownMenuItem(
                        text = { Text("Delete") },
                        onClick = { showMenu = false; onDelete() }
                    )
                    if (onBlock != null) {
                        DropdownMenuItem(
                            text = { Text("Block Sender") },
                            onClick = { showMenu = false; onBlock() }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun GroupInputBar(
    text: String,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    replyTo: StoredMessage? = null,
    onClearReply: () -> Unit = {}
) {
    Surface(tonalElevation = 2.dp) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            if (replyTo != null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "↩ ${replyTo.body.take(60)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = onClearReply, modifier = Modifier.size(24.dp)) {
                        Icon(
                            androidx.compose.material.icons.Icons.Default.Close,
                            contentDescription = "Clear reply",
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = text,
                    onValueChange = onTextChange,
                    placeholder = { Text("Message group…") },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(24.dp),
                    maxLines = 4
                )
                Spacer(Modifier.width(8.dp))
                IconButton(onClick = onSend, enabled = text.isNotBlank()) {
                    Icon(
                        Icons.Default.Send,
                        contentDescription = "Send",
                        tint = if (text.isNotBlank()) Color(0xFF007AFF)
                               else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.3f)
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GroupMemberSheet(
    group: GroupInfo,
    peers: List<com.sophax.sophaxchat.protocol.KnownPeer>,
    myPeerID: String,
    onLeave: () -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp)
        ) {
            Text(group.name, style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold)
            Text(
                "${group.memberIDs.size} members",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
            )
            Spacer(Modifier.height(16.dp))

            group.memberIDs.forEach { memberID ->
                val peer = peers.firstOrNull { it.id == memberID }
                val name = when {
                    memberID == myPeerID -> "You"
                    peer != null -> peer.username
                    else -> memberID.take(12)
                }
                val isCreator = memberID == group.creatorID
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(name, modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyLarge)
                    if (isCreator) {
                        Text("Admin", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary)
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
            if (myPeerID != group.creatorID) {
                Button(
                    onClick = onLeave,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error
                    ),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Leave Group") }
            }
        }
    }
}
