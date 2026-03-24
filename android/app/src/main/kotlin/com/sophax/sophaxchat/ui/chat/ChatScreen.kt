package com.sophax.sophaxchat.ui.chat

import android.graphics.BitmapFactory
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sophax.sophaxchat.storage.AttachmentStore
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
    onSendImage: ((ByteArray) -> Unit)? = null,
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
    var prevSize  by remember { mutableIntStateOf(0) }

    // Mark all messages read when this screen opens
    LaunchedEffect(Unit) { onMarkRead() }

    // Scroll to bottom only on new messages (not on deletions)
    LaunchedEffect(messages.size) {
        if (messages.size > prevSize && messages.isNotEmpty()) {
            listState.scrollToItem(messages.size - 1)
        }
        prevSize = messages.size
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
                                color = if (peerOnline) Color(0xFF34C759)
                                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
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
            SharedInputBar(
                text    = inputText,
                replyTo = replyTo,
                onClearReply  = { replyTo = null },
                onTextChange  = { inputText = it },
                onSendImage   = onSendImage,
                onSend = {
                    if (inputText.isNotBlank()) {
                        val body = if (replyTo != null)
                            "> ${replyTo!!.body.take(60).replace("\n", " ")}\n${inputText.trim()}"
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
    var showMenu by remember { mutableStateOf(false) }
    val context = LocalContext.current

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
                    if (message.attachmentMimeType?.startsWith("image/") == true) {
                        val attachmentStore = remember { AttachmentStore(context) }
                        val bitmap = remember(message.id) {
                            try {
                                val bytes = attachmentStore.load(message.id)
                                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            } catch (_: Exception) { null }
                        }
                        if (bitmap != null) {
                            Image(
                                bitmap = bitmap.asImageBitmap(),
                                contentDescription = "Image",
                                modifier = Modifier
                                    .sizeIn(maxWidth = 200.dp, maxHeight = 200.dp)
                                    .clip(RoundedCornerShape(8.dp))
                            )
                        } else {
                            Text(text = "[image]", color = if (isSent) Color.White else MaterialTheme.colorScheme.onSurface)
                        }
                    } else {
                        Text(
                            text  = message.body,
                            color = if (isSent) Color.White else MaterialTheme.colorScheme.onSurface,
                            fontSize = 16.sp,
                            lineHeight = 22.sp
                        )
                    }
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
