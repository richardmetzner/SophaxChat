package com.sophax.sophaxchat

// SophaxForegroundService.kt
// SophaxChat — Android
//
// Keeps the TCP transport and DHT engine alive when the app is in the background.
// Started by AppState when the user leaves the app; stopped when the app returns.
// Tor is already running in its own foreground service (TorService) — this service
// only needs to keep the ChatManager process alive.

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat

class SophaxForegroundService : Service() {

    companion object {
        const val CHANNEL_ID      = "sophaxchat_background"
        const val NOTIFICATION_ID = 1001

        /** True while the service is in a started state (between onCreate and onDestroy). */
        @Volatile var isRunning: Boolean = false
            private set

        /**
         * True once the service has been started at least once in this process lifetime.
         * Used by SophaxRestartWorker to avoid launching the service before setup is done.
         */
        @Volatile var hasEverStarted: Boolean = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, SophaxForegroundService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SophaxForegroundService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning      = true
        hasEverStarted = true
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this, 0, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("SophaxChat")
            .setContentText("Listening for messages…")
            .setContentIntent(pending)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Background connection",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "Keeps SophaxChat connected in the background"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }
}
