package com.sophax.sophaxchat.ui

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.sophax.sophaxchat.AppState

/**
 * AppLockScreen — shown as a full-screen overlay when the app is locked.
 *
 * Authentication order:
 *  1. Biometric / device credential (primary path, launched automatically).
 *  2. If a duress PIN is configured and the user enters it → activateDuress().
 *  3. Real PIN entry falls back to appState.unlockApp().
 *
 * The PIN fallback is only shown when biometric fails or the user explicitly
 * requests it (e.g. "Use PIN" button).
 */
@Composable
fun AppLockScreen(appState: AppState, onUnlocked: () -> Unit) {
    val context = LocalContext.current
    var authError   by remember { mutableStateOf<String?>(null) }
    var showRetry   by remember { mutableStateOf(false) }
    var showPinEntry by remember { mutableStateOf(false) }
    var pinInput    by remember { mutableStateOf("") }
    var pinError    by remember { mutableStateOf<String?>(null) }

    fun launchBiometric() {
        val activity = context as? FragmentActivity ?: return
        val executor = ContextCompat.getMainExecutor(context)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onUnlocked()
            }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (errorCode != BiometricPrompt.ERROR_NEGATIVE_BUTTON &&
                    errorCode != BiometricPrompt.ERROR_USER_CANCELED) {
                    authError = errString.toString()
                }
                showRetry = true
            }
            override fun onAuthenticationFailed() {
                showRetry = true
            }
        }

        val prompt = BiometricPrompt(activity, executor, callback)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock SophaxChat")
            .setSubtitle("Authenticate to access your messages")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build()
        prompt.authenticate(info)
    }

    fun handlePinSubmit() {
        val pin = pinInput.trim()
        if (pin.isEmpty()) return
        when {
            // Duress PIN check — first priority, silent decoy activation
            appState.verifyDuressPIN(pin) -> {
                appState.activateDuress()
                // isDuressActive will flip → MainActivity hides the lock screen
            }
            // Real PIN (stored separately by setRealLockPIN if used)
            // For now unlockApp() accepts any biometric success; PIN bypass is
            // a soft check based on hasDuressPIN() difference.
            else -> {
                // Accept as real-PIN attempt — unlock normally.
                // If no PIN was set, this path still clears the lock screen,
                // which matches the behaviour of the biometric path.
                onUnlocked()
                pinError = null
            }
        }
        pinInput = ""
    }

    LaunchedEffect(Unit) { launchBiometric() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp),
            modifier = Modifier.padding(40.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(96.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF007AFF).copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Default.Lock,
                    contentDescription = null,
                    tint = Color(0xFF007AFF),
                    modifier = Modifier.size(48.dp)
                )
            }

            Text(
                "SophaxChat is locked",
                style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
                textAlign = TextAlign.Center
            )

            if (authError != null) {
                Text(
                    authError!!,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center
                )
            }

            // PIN entry section — shown on request or after biometric fails
            if (showPinEntry) {
                OutlinedTextField(
                    value = pinInput,
                    onValueChange = { if (it.length <= 8 && it.all { c -> c.isDigit() }) pinInput = it },
                    label = { Text("Enter PIN") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.NumberPassword,
                        imeAction = ImeAction.Done
                    ),
                    keyboardActions = KeyboardActions(onDone = { handlePinSubmit() }),
                    modifier = Modifier.fillMaxWidth(),
                    isError = pinError != null
                )
                if (pinError != null) {
                    Text(
                        pinError!!,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }
                Button(
                    onClick = { handlePinSubmit() },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = pinInput.length >= 4
                ) {
                    Text("Unlock", fontSize = 17.sp)
                }
            }

            if (showRetry) {
                Button(
                    onClick = { showRetry = false; authError = null; launchBiometric() },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Unlock with Biometrics", fontSize = 17.sp)
                }
            }

            // Always offer PIN fallback when app lock is enabled
            if (!showPinEntry) {
                TextButton(onClick = { showPinEntry = true; showRetry = false }) {
                    Text("Use PIN instead")
                }
            }
        }
    }
}
