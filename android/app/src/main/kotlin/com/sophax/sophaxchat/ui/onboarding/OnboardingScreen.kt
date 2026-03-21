package com.sophax.sophaxchat.ui.onboarding

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

private data class OnboardingPage(
    val icon: String,
    val iconColor: Color,
    val title: String,
    val body: String
)

private val pages = listOf(
    OnboardingPage("🔒", Color(0xFF007AFF), "Private by design",
        "No servers. No accounts. Messages travel directly between devices, encrypted end-to-end."),
    OnboardingPage("📡", Color(0xFF34C759), "Find people nearby",
        "Open the app on the same WiFi or Bluetooth range. Nearby devices appear instantly."),
    OnboardingPage("🌐", Color(0xFFFF9500), "Chat globally",
        "Enable Tor in Settings to reach anyone in the world — no phone number, no VPN."),
    OnboardingPage("👤", Color(0xFF007AFF), "Choose your name",
        "")
)

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun OnboardingScreen(onComplete: (username: String) -> Unit) {
    val pagerState = rememberPagerState(pageCount = { pages.size })
    val scope = rememberCoroutineScope()
    var username by remember { mutableStateOf("") }
    val isLastPage = pagerState.currentPage == pages.size - 1

    Box(modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {

        HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { pageIndex ->
            val page = pages[pageIndex]
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 40.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                // Icon circle
                Box(
                    modifier = Modifier
                        .size(100.dp)
                        .clip(CircleShape)
                        .background(page.iconColor.copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center
                ) {
                    Text(page.icon, fontSize = 48.sp)
                }

                Spacer(Modifier.height(32.dp))

                Text(
                    page.title,
                    style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold),
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onBackground
                )

                Spacer(Modifier.height(16.dp))

                if (page.body.isNotEmpty()) {
                    Text(
                        page.body,
                        style = MaterialTheme.typography.bodyLarge,
                        textAlign = TextAlign.Center,
                        color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.6f),
                        lineHeight = 26.sp
                    )
                }

                // Username field on last page
                if (pageIndex == pages.size - 1) {
                    Spacer(Modifier.height(32.dp))
                    OutlinedTextField(
                        value = username,
                        onValueChange = { if (it.length <= 64) username = it },
                        label = { Text("Username") },
                        placeholder = { Text("e.g. alice") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(
                            onDone = { if (username.isNotBlank()) onComplete(username.trim()) }
                        )
                    )
                    Spacer(Modifier.height(24.dp))
                    Button(
                        onClick = { if (username.isNotBlank()) onComplete(username.trim()) },
                        enabled = username.isNotBlank(),
                        modifier = Modifier.fillMaxWidth().height(52.dp),
                        shape = RoundedCornerShape(14.dp)
                    ) {
                        Text("Start Chatting", fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                    }
                }
            }
        }

        // Page dots
        Row(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            repeat(pages.size) { i ->
                Box(
                    modifier = Modifier
                        .size(if (i == pagerState.currentPage) 10.dp else 7.dp)
                        .clip(CircleShape)
                        .background(
                            if (i == pagerState.currentPage)
                                MaterialTheme.colorScheme.primary
                            else
                                MaterialTheme.colorScheme.primary.copy(alpha = 0.3f)
                        )
                )
            }
        }

        // Skip button (pages 1–3)
        if (!isLastPage) {
            TextButton(
                onClick = { scope.launch { pagerState.scrollToPage(pages.size - 1) } },
                modifier = Modifier.align(Alignment.TopEnd).padding(top = 16.dp, end = 16.dp)
            ) {
                Text("Skip", color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}
