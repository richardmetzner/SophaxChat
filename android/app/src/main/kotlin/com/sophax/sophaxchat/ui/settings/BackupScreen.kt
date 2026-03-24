package com.sophax.sophaxchat.ui.settings

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sophax.sophaxchat.AppState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackupScreen(appState: AppState, onBack: () -> Unit) {
    var passphrase  by remember { mutableStateOf("") }
    var confirm     by remember { mutableStateOf("") }
    var statusText  by remember { mutableStateOf<String?>(null) }
    var isError     by remember { mutableStateOf(false) }

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream")
    ) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        val result = appState.exportBackup(passphrase, uri)
        isError = result != null
        statusText = result ?: "Backup saved."
        if (result == null) { passphrase = ""; confirm = "" }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        val result = appState.importBackup(passphrase, uri)
        isError = result != null
        statusText = result ?: "Backup restored. Restart the app to see all messages."
        if (result == null) passphrase = ""
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Backup & Restore") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                "Your backup is encrypted with your passphrase. Nobody can open it without it.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f)
            )

            SectionLabel("Export Backup")

            OutlinedTextField(
                value = passphrase,
                onValueChange = { passphrase = it },
                label = { Text("Passphrase") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = confirm,
                onValueChange = { confirm = it },
                label = { Text("Confirm passphrase") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                onClick = { exportLauncher.launch("sophaxchat-backup.bin") },
                enabled = passphrase.length >= 8 && passphrase == confirm,
                modifier = Modifier.fillMaxWidth()
            ) { Text("Export Encrypted Backup") }

            HorizontalDivider()
            SectionLabel("Restore Backup")

            OutlinedTextField(
                value = passphrase,
                onValueChange = { passphrase = it },
                label = { Text("Passphrase") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                onClick = { importLauncher.launch(arrayOf("application/octet-stream", "*/*")) },
                enabled = passphrase.isNotEmpty(),
                modifier = Modifier.fillMaxWidth()
            ) { Text("Choose Backup File\u2026") }

            statusText?.let { msg ->
                Text(
                    msg,
                    color = if (isError) MaterialTheme.colorScheme.error
                            else MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.bodyMedium
                )
            }

            HorizontalDivider()
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("\u2713 Messages and contacts are backed up", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
                Text("\uD83D\uDD12 Identity keys are NOT exported (by design)", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
                Text("\u2139 Contacts will ask to re-verify safety numbers", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
            }
        }
    }
}
