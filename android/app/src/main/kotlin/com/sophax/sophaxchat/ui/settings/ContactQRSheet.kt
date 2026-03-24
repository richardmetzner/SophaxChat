package com.sophax.sophaxchat.ui.settings

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactQRSheet(contactUrl: String, onDismiss: () -> Unit) {
    val qrBitmap = remember(contactUrl) { generateQRBitmap(contactUrl) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text("Share Your Address", style = MaterialTheme.typography.titleMedium)

            qrBitmap?.let {
                Image(
                    bitmap = it.asImageBitmap(),
                    contentDescription = "QR code",
                    modifier = Modifier.size(240.dp)
                )
            } ?: Text("No address configured. Enable TCP in Network settings first.")

            Text(
                contactUrl,
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
            )

            Text(
                "Others can scan this to add you as a contact.",
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
            )

            Spacer(Modifier.height(8.dp))
        }
    }
}

private fun generateQRBitmap(content: String): Bitmap? {
    if (content.isBlank()) return null
    return try {
        val bits = MultiFormatWriter().encode(content, BarcodeFormat.QR_CODE, 512, 512)
        val w = bits.width
        val h = bits.height
        val pixels = IntArray(w * h) { i -> if (bits[i % w, i / w]) Color.BLACK else Color.WHITE }
        Bitmap.createBitmap(w, h, Bitmap.Config.RGB_565).also { it.setPixels(pixels, 0, w, 0, 0, w, h) }
    } catch (_: Exception) { null }
}
