package com.write4me.llama_flutter_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class InferenceService : Service() {
    private val binder = InferenceBinder()
    private val notificationId = 1
    private val channelId = "InferenceServiceChannel"
    private val channelName = "AI Inference Service"
    private val channelDescription = "Foreground service for AI model inference"

    inner class InferenceBinder : Binder() {
        fun getService(): InferenceService = this@InferenceService
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createNotification().build()
        startForeground(notificationId, notification)

        return START_STICKY  // Restart if killed
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    private fun createNotification(): NotificationCompat.Builder {
        return NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)  // Use a proper icon in real implementation
            .setContentTitle("AI Model Inference Running")
            .setContentText("Processing requests using local model")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setSound(null)  // No sound needed for this service
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