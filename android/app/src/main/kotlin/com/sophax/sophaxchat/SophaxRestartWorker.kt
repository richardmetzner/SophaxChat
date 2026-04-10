package com.sophax.sophaxchat

// SophaxRestartWorker.kt
// SophaxChat — Android
//
// Periodic WorkManager task (every 15 min) that checks whether
// SophaxForegroundService is running and restarts it if the OS or an
// aggressive OEM ROM (Xiaomi MIUI, Huawei EMUI, etc.) has killed it.
//
// Scheduling: WorkManager ensures this job survives process death and
// device reboots (BOOT_COMPLETED is handled by WorkManager internally).

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

class SophaxRestartWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {

    companion object {
        private const val WORK_NAME = "sophaxchat_watchdog"

        /**
         * Schedule a periodic watchdog that runs every 15 minutes (WorkManager minimum).
         * Uses KEEP policy — if the work is already enqueued, do nothing.
         * Should be called once at app startup from AppState.
         */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SophaxRestartWorker>(
                repeatInterval = 15,
                repeatIntervalTimeUnit = TimeUnit.MINUTES
            ).build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }

        /** Cancel the watchdog — call when the user wipes account or disables background activity. */
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
    }

    override suspend fun doWork(): Result {
        // Only restart if the service was previously started (i.e. setup is complete
        // and the app has been backgrounded at least once). If it was never started,
        // hasEverStarted is false and we skip — avoids launching the service before
        // the user has set up an identity.
        if (SophaxForegroundService.hasEverStarted && !SophaxForegroundService.isRunning) {
            SophaxForegroundService.start(applicationContext)
        }
        return Result.success()
    }
}
