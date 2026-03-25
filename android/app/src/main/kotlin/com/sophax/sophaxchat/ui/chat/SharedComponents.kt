package com.sophax.sophaxchat.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sophax.sophaxchat.storage.AttachmentStore
import com.sophax.sophaxchat.storage.StoredMessage

internal fun copyToClipboard(context: Context, text: String) {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("message", text))
    // Auto-clear after 60 s — matches iOS implementation.
    // Only clears if the clipboard still contains the exact text we set.
    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
        val current = cm.primaryClip?.getItemAt(0)?.text?.toString()
        if (current == text) cm.setPrimaryClip(ClipData.newPlainText("", ""))
    }, 60_000L)
}

private val REACTION_EMOJIS = listOf("👍", "❤️", "😂", "😮", "😢", "🙏")

@Composable
fun MessageContextMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    body: String,
    onReply: () -> Unit,
    onDelete: () -> Unit,
    onBlock: (() -> Unit)? = null,
    onReact: ((String) -> Unit)? = null
) {
    val context = LocalContext.current
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        if (onReact != null) {
            Row(
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                REACTION_EMOJIS.forEach { emoji ->
                    TextButton(
                        onClick = { onDismiss(); onReact(emoji) },
                        contentPadding = PaddingValues(4.dp),
                        modifier = Modifier.size(40.dp)
                    ) { Text(emoji, fontSize = 20.sp) }
                }
            }
            HorizontalDivider()
        }
        DropdownMenuItem(
            text = { Text("Reply") },
            onClick = { onDismiss(); onReply() }
        )
        DropdownMenuItem(
            text = { Text("Copy") },
            onClick = { onDismiss(); copyToClipboard(context, body) }
        )
        DropdownMenuItem(
            text = { Text("Delete") },
            onClick = { onDismiss(); onDelete() }
        )
        if (onBlock != null) {
            DropdownMenuItem(
                text = { Text("Block Sender") },
                onClick = { onDismiss(); onBlock() }
            )
        }
    }
}

@Composable
fun SharedInputBar(
    text: String,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    onSendImage: ((ByteArray) -> Unit)? = null,
    placeholder: String = "Message",
    maxLines: Int = 5,
    tonalElevation: Dp = 3.dp,
    replyTo: StoredMessage? = null,
    onClearReply: () -> Unit = {}
) {
    Surface(
        tonalElevation = tonalElevation,
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
                            Icons.Default.Close,
                            contentDescription = "Clear reply",
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
            }
            Row(verticalAlignment = Alignment.Bottom) {
                if (onSendImage != null) {
                    val context = LocalContext.current
                    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
                        uri ?: return@rememberLauncherForActivityResult
                        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@rememberLauncherForActivityResult
                        if (bytes.size <= AttachmentStore.MAX_BYTES) onSendImage(bytes)
                    }
                    IconButton(
                        onClick = { imagePicker.launch("image/*") },
                        modifier = Modifier.size(48.dp)
                    ) {
                        Icon(
                            Icons.Default.AttachFile,
                            contentDescription = "Attach image",
                            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                        )
                    }
                    Spacer(Modifier.width(4.dp))
                }
                OutlinedTextField(
                    value = text,
                    onValueChange = onTextChange,
                    placeholder = { Text(placeholder) },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(24.dp),
                    maxLines = maxLines
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
