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
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.VerifiedUser
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
import com.sophax.sophaxchat.storage.MessageDirection
import com.sophax.sophaxchat.storage.MessageStatus
import com.sophax.sophaxchat.storage.StoredMessage
import java.text.SimpleDateFormat
import java.util.Locale

private val timeFmt = SimpleDateFormat("HH:mm", Locale.getDefault())

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    peerUsername: String,
    peerOnline: Boolean,
    messages: List<StoredMessage>,
    peerID: String = "",
    onSend: (String) -> Unit,
    onBack: () -> Unit,
    onMarkRead: () -> Unit = {},
    isTyping: Boolean = false,
    onTyping: () -> Unit = {},
    onDeleteMessage: (messageID: String) -> Unit = {},
    onBlockPeer: (peerID: String) -> Unit = {},
    onSafetyNumber: () -> Unit = {}
) {
    var inputText by remember { mutableStateOf("") }
    var replyTo   by remember { mutableStateOf<StoredMessage?>(null) }
    val listState = rememberLazyListState()

    // Mark all messages read when this screen opens
    LaunchedEffect(Unit) { onMarkRead() }

    // Scroll to bottom on new messages
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.scrollToItem(messages.size - 1)
    }

    // Send typing event when user is typing (debounced 500ms)
    LaunchedEffect(inputText) {
        if (inputText.isNotEmpty()) {
            kotlinx.coroutines.delay(500)
            onTyping()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(peerUsername, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                        if (isTyping) {
                            Text(
                                "typing…",
                                fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.primary
                            )
                        } else {
                            Text(
                                if (peerOnline) "Online" else "Offline",
                                fontSize = 12.sp,
                                color = if (peerOnline) Color(0xFF34C759) else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
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
                    IconButton(onClick = onSafetyNumber) {
                        Icon(Icons.Default.VerifiedUser, contentDescription = "Safety Number")
                    }
                }
            )
        },
        bottomBar = {
            InputBar(
                text    = inputText,
                replyTo = replyTo,
                onClearReply  = { replyTo = null },
                onTextChange  = { inputText = it },
                onSend = {
                    if (inputText.isNotBlank()) {
                        val body = if (replyTo != null)
                            "> ${replyTo!!.body.take(60)}\n${inputText.trim()}"
                        else inputText.trim()
                        onSend(body)
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
                .padding(padding)
                .fillMaxSize()
                .padding(horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
            contentPadding = PaddingValues(vertical = 12.dp)
        ) {
            items(messages, key = { it.id }) { message ->
                MessageBubble(
                    message  = message,
                    onDelete = { onDeleteMessage(message.id) },
                    onBlock  = if (!message.isSent) ({ onBlockPeer(message.peerID) }) else null,
                    onReply  = { replyTo = message }
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(
    message: StoredMessage,
    onDelete: () -> Unit = {},
    onBlock: (() -> Unit)? = null,
    onReply: () -> Unit = {}
) {
    val isSent = message.direction == MessageDirection.sent.name
    val context = LocalContext.current
    var showMenu by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isSent) Arrangement.End else Arrangement.Start
    ) {
        Column(
            horizontalAlignment = if (isSent) Alignment.End else Alignment.Start,
            modifier = Modifier.widthIn(max = 280.dp)
        ) {
            Box {
                Box(
                    modifier = Modifier
                        .clip(
                            RoundedCornerShape(
                                topStart = 18.dp, topEnd = 18.dp,
                                bottomStart = if (isSent) 18.dp else 4.dp,
                                bottomEnd   = if (isSent) 4.dp else 18.dp
                            )
                        )
                        .background(
                            if (isSent) Color(0xFF007AFF)
                            else MaterialTheme.colorScheme.surfaceVariant
                        )
                        .combinedClickable(
                            onClick = {},
                            onLongClick = { showMenu = true }
                        )
                        .padding(horizontal = 14.dp, vertical = 9.dp)
                ) {
                    Text(
                        text  = message.body,
                        color = if (isSent) Color.White else MaterialTheme.colorScheme.onSurface,
                        fontSize = 16.sp,
                        lineHeight = 22.sp
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

            Spacer(Modifier.height(2.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    timeFmt.format(message.timestamp),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f)
                )
                if (isSent) {
                    Text(
                        when (message.status) {
                            MessageStatus.delivered.name -> "✓✓"
                            MessageStatus.read.name      -> "✓✓"
                            MessageStatus.sending.name   -> "✓"
                            else -> ""
                        },
                        fontSize = 11.sp,
                        color = when (message.status) {
                            MessageStatus.read.name -> Color(0xFF007AFF)
                            else -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f)
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun InputBar(
    text: String,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    replyTo: StoredMessage? = null,
    onClearReply: () -> Unit = {}
) {
    Surface(
        tonalElevation = 3.dp,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier
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
            Row(verticalAlignment = Alignment.Bottom) {
                OutlinedTextField(
                    value = text,
                    onValueChange = onTextChange,
                    placeholder = { Text("Message") },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(24.dp),
                    maxLines = 5
                )
                Spacer(Modifier.width(8.dp))
                IconButton(
                    onClick = onSend,
                    enabled = text.isNotBlank(),
                    modifier = Modifier
                        .size(48.dp)
                        .clip(RoundedCornerShape(50))
                        .background(
                            if (text.isNotBlank()) Color(0xFF007AFF)
                            else MaterialTheme.colorScheme.surfaceVariant
                        )
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.Send,
                        contentDescription = "Send",
                        tint = if (text.isNotBlank()) Color.White
                               else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f)
                    )
                }
            }
        }
    }
}
