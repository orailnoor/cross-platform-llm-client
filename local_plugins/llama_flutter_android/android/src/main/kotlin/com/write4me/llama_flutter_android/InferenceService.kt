package com.write4me.llama_flutter_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

class InferenceService : Service() {
    private val binder = InferenceBinder()
    private val notificationId = 1
    private val channelId = "InferenceServiceChannel"
    private val channelName = "AI Inference Service"
    private val channelDescription = "Foreground service for AI model inference"

    companion object {
        private const val TAG = "InferenceService"
        /** Hold a partial wake lock + high-performance Wi-Fi lock (API server). */
        const val ACTION_KEEP_AWAKE_ON = "com.write4me.llama_flutter_android.KEEP_AWAKE_ON"
        const val ACTION_KEEP_AWAKE_OFF = "com.write4me.llama_flutter_android.KEEP_AWAKE_OFF"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        @Volatile var isRunning = false
            private set
        /** Keep-awake is on: unloading the model must not stop this service. */
        @Volatile var keepAwake = false
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var title: String? = null
    private var text: String? = null

    inner class InferenceBinder : Binder() {
        fun getService(): InferenceService = this@InferenceService
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_KEEP_AWAKE_ON -> {
                title = intent.getStringExtra(EXTRA_TITLE)
                text = intent.getStringExtra(EXTRA_TEXT)
                acquireLocks()
            }
            ACTION_KEEP_AWAKE_OFF -> {
                title = null
                text = null
                releaseLocks()
            }
        }
        val notification = createNotification().build()
        startForeground(notificationId, notification)

        return START_STICKY  // Restart if killed
    }

    override fun onDestroy() {
        releaseLocks()
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    private fun acquireLocks() {
        if (wakeLock?.isHeld != true) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PrivateLM:ApiServer").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock?.isHeld != true) {
            try {
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "PrivateLM:ApiServer").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Wi-Fi lock unavailable: ${e.message}")
            }
        }
        keepAwake = true
        Log.i(TAG, "Keep-awake on (wake lock + Wi-Fi lock)")
    }

    private fun releaseLocks() {
        keepAwake = false
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    private fun createNotification(): NotificationCompat.Builder {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launch?.let {
            PendingIntent.getActivity(this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        return NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)  // Use a proper icon in real implementation
            .setContentTitle(title ?: "AI Model Inference Running")
            .setContentText(text ?: "Processing requests using local model")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setSound(null)  // No sound needed for this service
            .apply { if (pending != null) setContentIntent(pending) }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                channelName,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = channelDescription
                setSound(null, null)  // Disable sound
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }
}
