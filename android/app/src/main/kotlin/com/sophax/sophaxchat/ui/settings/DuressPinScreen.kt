package com.sophax.sophaxchat.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.sophax.sophaxchat.AppState

/**
 * DuressPinScreen
 *
 * Lets the user set (or clear) a Duress PIN. When the duress PIN is entered
 * on the lock screen instead of the real PIN, the app activates a silent decoy
 * mode — all conversations appear empty and incoming messages are silently
 * dropped. The real app data is untouched; it becomes accessible again after a
 * real (biometric / PIN) unlock.
 *
 * Security requirements:
 *  • Duress PIN must be 4–8 digits.
 *  • It must differ from the real lock PIN (enforced at save time).
 *  • It is stored in EncryptedSharedPreferences — not in plain SharedPreferences.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DuressPinScreen(appState: AppState, onBack: () -> Unit) {
    var pin         by remember { mutableStateOf("") }
    var confirm     by remember { mutableStateOf("") }
    var errorText   by remember { mutableStateOf<String?>(null) }
    var successText by remember { mutableStateOf<String?>(null) }
    var hasPin      by remember { mutableStateOf(appState.hasDuressPIN()) }

    val isValid: Boolean
        get() {
            if (pin.length < 4 || pin.length > 8) return false
            if (!pin.all { it.isDigit() }) return false
            if (pin != confirm) return false
            return true
        }

    fun save() {
        errorText   = null
        successText = null
        try {
            appState.setDuressPIN(pin)
            hasPin      = true
            successText = "Duress PIN saved."
            pin         = ""
            confirm     = ""
        } catch (e: IllegalArgumentException) {
            errorText = e.message
        }
    }

    fun clear() {
        appState.clearDuressPIN()
        hasPin      = false
        successText = "Duress PIN removed."
        pin         = ""
        confirm     = ""
        errorText   = null
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Duress PIN") },
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
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // ----------------------------------------------------------------
            // Explanation card
            // ----------------------------------------------------------------
            Card(
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.secondaryContainer
                )
            ) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.Info,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.secondary
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "What is a Duress PIN?",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                    Text(
                        "If you are forced to unlock your phone, enter this PIN instead of your real PIN. " +
                        "The app will show an empty state — no messages, no contacts. " +
                        "Your real data stays safe and will be accessible again after a legitimate unlock.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSecondaryContainer
                    )
                }
            }

            // ----------------------------------------------------------------
            // Warning list
            // ----------------------------------------------------------------
            Card(
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.4f)
                )
            ) {
                Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.Warning,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "Entering this PIN will NOT unlock the real app",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                    Text("• App shows an empty state with no data", style = MaterialTheme.typography.bodySmall)
                    Text("• Incoming messages are silently dropped", style = MaterialTheme.typography.bodySmall)
                    Text("• Must differ from your real lock PIN", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error)
                }
            }

            // ----------------------------------------------------------------
            // Current status
            // ----------------------------------------------------------------
            if (hasPin) {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.primaryContainer
                    )
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Duress PIN is set", style = MaterialTheme.typography.bodyMedium)
                        OutlinedButton(
                            onClick = { clear() },
                            colors = ButtonDefaults.outlinedButtonColors(
                                contentColor = MaterialTheme.colorScheme.error
                            )
                        ) {
                            Text("Remove")
                        }
                    }
                }
            }

            HorizontalDivider()

            // ----------------------------------------------------------------
            // PIN entry form
            // ----------------------------------------------------------------
            Text(
                if (hasPin) "Change Duress PIN" else "Set Duress PIN",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary
            )

            OutlinedTextField(
                value = pin,
                onValueChange = {
                    if (it.length <= 8 && it.all { c -> c.isDigit() }) {
                        pin = it
                        errorText   = null
                        successText = null
                    }
                },
                label = { Text("Duress PIN (4–8 digits)") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = confirm,
                onValueChange = {
                    if (it.length <= 8 && it.all { c -> c.isDigit() }) {
                        confirm = it
                        errorText   = null
                        successText = null
                    }
                },
                label = { Text("Confirm Duress PIN") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                modifier = Modifier.fillMaxWidth(),
                isError = confirm.isNotEmpty() && pin != confirm
            )

            if (confirm.isNotEmpty() && pin != confirm) {
                Text(
                    "PINs do not match.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }

            errorText?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
            successText?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            }

            Button(
                onClick = { save() },
                enabled = isValid,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(if (hasPin) "Update Duress PIN" else "Save Duress PIN")
            }
        }
    }
}
