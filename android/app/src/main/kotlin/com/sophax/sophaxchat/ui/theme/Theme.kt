package com.sophax.sophaxchat.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// SophaxChat brand color — matches iOS accentColor
private val SophaxBlue     = Color(0xFF007AFF)
private val SophaxBlueDark = Color(0xFF0A84FF)

private val LightColors = lightColorScheme(
    primary          = SophaxBlue,
    onPrimary        = Color.White,
    primaryContainer = Color(0xFFD6E4FF),
    secondary        = SophaxBlue,
    background       = Color(0xFFF2F2F7),
    surface          = Color.White,
    surfaceVariant   = Color(0xFFEEEEF0),
)

private val DarkColors = darkColorScheme(
    primary          = SophaxBlueDark,
    onPrimary        = Color.White,
    primaryContainer = Color(0xFF001D36),
    secondary        = SophaxBlueDark,
    background       = Color(0xFF000000),
    surface          = Color(0xFF1C1C1E),
    surfaceVariant   = Color(0xFF2C2C2E),
)

@Composable
fun SophaxChatTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content
    )
}
