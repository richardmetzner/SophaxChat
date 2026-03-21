package com.sophax.sophaxchat.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.sophax.sophaxchat.MainActivity

object NotificationHelper {
    const val CHANNEL_ID = "sophaxchat_messages"

    fun createChannel(context: Context) {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Messages",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming SophaxChat messages"
        }
        context.getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    fun showMessage(
        context: Context,
        title: String,
        body: String,
        conversationID: String,
        messageID: String
    ) {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("conversationID", conversationID)
        }
        val pending = PendingIntent.getActivity(
            context, messageID.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(title)
            .setContentText(body)
            .setGroup(conversationID)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        context.getSystemService(NotificationManager::class.java)
            .notify(messageID.hashCode(), notification)
    }

    fun cancelMessage(context: Context, messageID: String) {
        context.getSystemService(NotificationManager::class.java)
            .cancel(messageID.hashCode())
    }

    fun cancelConversation(context: Context, messageIDs: List<String>) {
        val mgr = context.getSystemService(NotificationManager::class.java)
        messageIDs.forEach { mgr.cancel(it.hashCode()) }
    }
}
