package com.alist.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class AlistService : Service() {
    companion object {
        const val ACTION_START = "com.alist.android.action.START"
        const val ACTION_STOP = "com.alist.android.action.STOP"
        const val ACTION_STATUS = "com.alist.android.action.STATUS"
        const val EXTRA_ERROR = "error"

        private const val CHANNEL_ID = "alist-backend"
        private const val NOTIFICATION_ID = 5244
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "alist-backend").apply { isDaemon = false }
    }
    private val starting = AtomicBoolean(false)
    @Volatile
    private var running = false
    @Volatile
    private var destroyed = false
    private var nativeBridge: NativeBridge? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        if (action == ACTION_STOP) {
            stopBackendAndSelf()
            return START_NOT_STICKY
        }

        try {
            startForegroundCompat(buildNotification(getString(R.string.backend_starting)))
        } catch (error: Throwable) {
            broadcastStatus(error.message ?: error.javaClass.simpleName)
            stopSelf()
            return START_NOT_STICKY
        }
        startBackend()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        destroyed = true
        val stopFuture: Future<*> = executor.submit { stopNative() }
        try {
            stopFuture.get(3, TimeUnit.SECONDS)
        } catch (_: Exception) {
            stopFuture.cancel(true)
        }
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun startBackend() {
        if (running || !starting.compareAndSet(false, true)) return
        executor.execute {
            try {
                val dataDir = File(filesDir, "alist")
                val endpoint = BackendConfig.prepare(dataDir)
                val bridge = NativeBridge()
                nativeBridge = bridge
                val result = bridge.start(dataDir.absolutePath, endpoint.port)
                if (result != 0 && result != 1) {
                    throw IllegalStateException(bridge.lastError().ifBlank { "native backend returned $result" })
                }
                running = true
                updateNotification(getString(R.string.backend_running))
                broadcastStatus(null)
            } catch (error: Throwable) {
                running = false
                val message = error.message ?: error.javaClass.simpleName
                updateNotification(getString(R.string.backend_failed))
                broadcastStatus(message)
                if (!destroyed) stopSelf()
            } finally {
                starting.set(false)
            }
        }
    }

    private fun stopBackendAndSelf() {
        executor.execute {
            stopNative()
            running = false
            stopForegroundCompat()
            stopSelf()
        }
    }

    private fun stopNative() {
        val bridge = nativeBridge ?: return
        try {
            val result = bridge.stop()
            if (result != 0 && result != 1) {
                broadcastStatus(bridge.lastError().ifBlank { "native backend stop failed: $result" })
            }
        } catch (error: Throwable) {
            broadcastStatus(error.message ?: error.javaClass.simpleName)
        } finally {
            running = false
        }
    }

    private fun broadcastStatus(error: String?) {
        val status = Intent(ACTION_STATUS).setPackage(packageName)
        if (error != null) status.putExtra(EXTRA_ERROR, error)
        sendBroadcast(status)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.notification_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.notification_channel_description)
            },
        )
    }

    private fun buildNotification(text: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pendingIntent = PendingIntent.getActivity(this, 0, openIntent, flags)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_launcher)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
