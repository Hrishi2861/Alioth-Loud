package com.f3.aliothloud

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-attach after a reboot, but only if the user actually had it on. Starting a
 * foreground service unasked would be rude and would show a notification for a
 * feature that is switched off.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                if (Prefs(context).load().enabled) EngineService.start(context)
            }
        }
    }
}
