package com.orailnoor.privatelm

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Start-on-boot: runs the app's Dart side without a UI (a cached
 * FlutterEngine), so it can load the default model and start the API server
 * after a reboot. MainActivity reuses this engine when the user opens the app,
 * so there is never a second copy of the app running.
 */
class HeadlessService : Service() {
    companion object {
        private const val TAG = "HeadlessService"
        const val ENGINE_ID = "privatelm_main"
        private const val CHANNEL_ID = "PrivateLMHeadless"
        private const val NOTIFICATION_ID = 7
        const val PREFS = "privatelm_autostart"
        const val KEY_START_ON_BOOT = "start_on_boot"

        /** The shared engine, creating and starting it if needed. */
        fun obtainEngine(context: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
            val app = context.applicationContext
            val loader = FlutterInjector.instance().flutterLoader()
            if (!loader.initialized()) {
                loader.startInitialization(app)
                loader.ensureInitializationComplete(app, null)
            }
            val engine = FlutterEngine(app)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            Log.i(TAG, "Started headless Flutter engine")
            return engine
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launch?.let {
            PendingIntent.getActivity(this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("PrivateLM is running")
            .setContentText("Started at boot: loading the model and the API server")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .apply { if (pending != null) setContentIntent(pending) }
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Could not start in the foreground", e)
        }
        try {
            obtainEngine(this)
        } catch (e: Exception) {
            Log.e(TAG, "Headless engine failed", e)
            stopSelf()
        }
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Background start",
                NotificationManager.IMPORTANCE_LOW).apply { setSound(null, null) }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
}
