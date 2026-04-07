package com.sophax.sophaxchat.ui.settings

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.sophax.sophaxchat.AppState
import com.sophax.sophaxchat.protocol.KnownPeer

/**
 * LinkedDevicesScreen
 *
 * Manage devices linked to this account (same person, multiple devices).
 * Device B scans Device A's QR code; both sides then exchange PreKeyBundles
 * so they can maintain DR sessions and forward messages to each other.
 *
 * Linking flow:
 *  1. On Device A: tap "Show QR Code" → display DeviceLinkRequestMessage as QR.
 *  2. On Device B: tap "Scan QR" → scan Device A's QR → acceptDeviceLink() is called.
 *  3. Both devices now have each other's bundle; a reciprocal link request is sent automatically.
 *
 * Note: QR scanning uses the same camera permission and pattern as ContactScannerView.
 * A full ZXing/ML Kit camera scanner integration is required for the "Scan QR" path —
 * placeholder launch via ACTION_IMAGE_CAPTURE intent until barcode scanner is integrated.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3Api::class)
@Composable
fun LinkedDevicesScreen(appState: AppState, onBack: () -> Unit) {
    val linkedDevices by appState.linkedDevices.collectAsState()

    var showQR       by remember { mutableStateOf(false) }
    var deviceToUnlink by remember { mutableStateOf<KnownPeer?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Linked Devices") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item { Spacer(Modifier.height(4.dp)) }

            // ----------------------------------------------------------------
            // Info card
            // ----------------------------------------------------------------
            item {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.secondaryContainer
                    )
                ) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                Icons.Default.Devices,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.secondary,
                                modifier = Modifier.size(20.dp)
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "Link multiple devices",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                        Text(
                            "On Device A tap \"Show QR Code\", then on Device B tap \"Scan QR\" " +
                            "and point the camera at Device A's screen. Both devices must be in " +
                            "Bluetooth / Wi-Fi range after scanning.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSecondaryContainer
                        )
                    }
                }
            }

            // ----------------------------------------------------------------
            // Action buttons
            // ----------------------------------------------------------------
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedButton(
                        onClick = { showQR = true },
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.QrCode, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Show QR Code")
                    }
                    // NOTE: Full QR scanner integration (ZXing / ML Kit) is required here.
                    // The button is present as a scaffold; wire it up to your camera scanner.
                    Button(
                        onClick = { /* TODO: launch camera scanner → appState.acceptDeviceLink(data) */ },
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Scan QR")
                    }
                }
            }

            // ----------------------------------------------------------------
            // Linked device list
            // ----------------------------------------------------------------
            if (linkedDevices.isNotEmpty()) {
                item {
                    Text(
                        "Linked Devices (${linkedDevices.size})",
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 8.dp)
                    )
                }
                items(linkedDevices, key = { it.id }) { peer ->
                    LinkedDeviceRow(
                        peer     = peer,
                        onUnlink = { deviceToUnlink = peer }
                    )
                }
            } else {
                item {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 32.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(
                                Icons.Default.DevicesOther,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.3f),
                                modifier = Modifier.size(48.dp)
                            )
                            Text(
                                "No linked devices yet",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                            )
                        }
                    }
                }
            }

            item { Spacer(Modifier.height(16.dp)) }
        }
    }

    // QR code sheet
    if (showQR) {
        val qrData = remember { appState.generateDeviceLinkQR() }
        DeviceLinkQRDialog(data = qrData, onDismiss = { showQR = false })
    }

    // Unlink confirmation
    deviceToUnlink?.let { peer ->
        AlertDialog(
            onDismissRequest = { deviceToUnlink = null },
            title = { Text("Unlink \"${peer.username}\"?") },
            text  = { Text("Messages will no longer sync to this device. This cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        appState.unlinkDevice(peer)
                        deviceToUnlink = null
                    }
                ) {
                    Text("Unlink", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { deviceToUnlink = null }) { Text("Cancel") }
            }
        )
    }
}

// ---------------------------------------------------------------------------
// Device row
// ---------------------------------------------------------------------------

@Composable
private fun LinkedDeviceRow(peer: KnownPeer, onUnlink: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Default.PhoneAndroid,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(22.dp)
                )
            }

            Spacer(Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(peer.username, style = MaterialTheme.typography.bodyLarge)
                Text(
                    peer.id.take(8) + "…",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                )
                if (!peer.isOnline) {
                    peer.lastSeen?.let { seen ->
                        Text(
                            "Last seen ${java.text.SimpleDateFormat("MMM d, HH:mm", java.util.Locale.getDefault()).format(seen)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f)
                        )
                    }
                }
            }

            if (peer.isOnline) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(androidx.compose.ui.graphics.Color.Green)
                )
                Spacer(Modifier.width(8.dp))
            }

            IconButton(onClick = onUnlink) {
                Icon(
                    Icons.Default.LinkOff,
                    contentDescription = "Unlink",
                    tint = MaterialTheme.colorScheme.error
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// QR code dialog
// ---------------------------------------------------------------------------

@Composable
private fun DeviceLinkQRDialog(data: ByteArray?, onDismiss: () -> Unit) {
    val qrBitmap: Bitmap? = remember(data) {
        if (data == null) return@remember null
        try {
            val text = String(data)
            val hints = mapOf(EncodeHintType.MARGIN to 1)
            val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 512, 512, hints)
            val bmp = Bitmap.createBitmap(512, 512, Bitmap.Config.ARGB_8888)
            for (x in 0 until 512) for (y in 0 until 512) {
                bmp.setPixel(x, y, if (matrix[x, y]) Color.BLACK else Color.WHITE)
            }
            bmp
        } catch (_: Exception) { null }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Link This Device") },
        text = {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    "Scan this QR code with your other device.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                )
                if (qrBitmap != null) {
                    Image(
                        bitmap = qrBitmap.asImageBitmap(),
                        contentDescription = "Device link QR code",
                        modifier = Modifier
                            .size(240.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(androidx.compose.ui.graphics.Color.White)
                            .padding(8.dp)
                    )
                } else {
                    CircularProgressIndicator(modifier = Modifier.size(64.dp))
                }
                Text(
                    "Keep both devices in Bluetooth range after scanning.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Done") }
        }
    )
}
