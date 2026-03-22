package com.sophax.sophaxchat.ui.chat

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
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
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
    // Populate cache from disk on first open
    LaunchedEffect(group.conversationID) { appState.messagesFor(group.conversationID) }

    val allMessages by appState.messages.collectAsState()
    val messages    = allMessages[group.conversationID] ?: emptyList()

    val peers       by appState.peers.collectAsState()
    val typingPeers by appState.typingPeers.collectAsState()

    // Pre-index peers for O(1) lookup instead of O(n) scan per item
    val peerIndex = remember(peers) { peers.associateBy { it.id } }

    // O(1) membership check for typing filter
    val memberIDSet = remember(group.id, group.memberIDs) { group.memberIDs.toHashSet() }

    val typingNames = typingPeers
        .filter { it in memberIDSet }
        .mapNotNull { id -> peerIndex[id]?.username }

    // Stable recipient list — only recomputed when group membership changes
    val typingRecipients = remember(group.memberIDs, appState.myPeerID) {
        group.memberIDs.filter { it != appState.myPeerID }
    }

    var inputText       by remember { mutableStateOf("") }
    var replyTo         by remember { mutableStateOf<StoredMessage?>(null) }
    var showMemberSheet by remember { mutableStateOf(false) }
    val listState  = rememberLazyListState()
    var prevSize   by remember { mutableIntStateOf(0) }

    // Mark all messages read when this screen opens
    LaunchedEffect(Unit) { appState.markAsRead(group.conversationID) }

    // Send typing to each group member (debounced 500ms)
    LaunchedEffect(inputText) {
        if (inputText.isNotEmpty()) {
            kotlinx.coroutines.delay(500)
            typingRecipients.forEach { appState.sendTyping(it) }
        }
    }

    // Scroll to bottom only on new messages (not on deletions)
    LaunchedEffect(messages.size) {
        if (messages.size > prevSize && messages.isNotEmpty()) {
            listState.scrollToItem(messages.size - 1)
        }
        prevSize = messages.size
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
            SharedInputBar(
                text         = inputText,
                replyTo      = replyTo,
                onClearReply = { replyTo = null },
                onTextChange = { inputText = it },
                placeholder  = "Message group…",
                maxLines     = 4,
                tonalElevation = 2.dp,
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
                    peerIndex[msg.peerID]?.username ?: msg.peerID.take(8)
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
            group    = group,
            peerIndex = peerIndex,
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
                MessageContextMenu(
                    expanded  = showMenu,
                    onDismiss = { showMenu = false },
                    body      = message.body,
                    onReply   = onReply,
                    onDelete  = onDelete,
                    onBlock   = onBlock
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GroupMemberSheet(
    group: GroupInfo,
    peerIndex: Map<String, com.sophax.sophaxchat.protocol.KnownPeer>,
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
                val name = when {
                    memberID == myPeerID -> "You"
                    else -> peerIndex[memberID]?.username ?: memberID.take(12)
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
