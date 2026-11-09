package com.orailnoor.privatelm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            // "Start on boot" (off by default): run the app headless in a
            // foreground service so it can load the default model and start
            // the API server without anyone opening it.
            val prefs = context.getSharedPreferences(HeadlessService.PREFS, Context.MODE_PRIVATE)
            if (prefs.getBoolean(HeadlessService.KEY_START_ON_BOOT, false)) {
                try {
                    ContextCompat.startForegroundService(context,
                        Intent(context, HeadlessService::class.java))
                    return
                } catch (e: Exception) {
                    Log.e("BootReceiver", "Headless start failed", e)
                }
            }
            val launchIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
            launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (launchIntent != null) {
                try {
                    context.startActivity(launchIntent)
                } catch (e: Exception) {
                    Log.w("BootReceiver", "Activity start at boot not allowed: ${e.message}")
                }
            }
        }
    }
}
