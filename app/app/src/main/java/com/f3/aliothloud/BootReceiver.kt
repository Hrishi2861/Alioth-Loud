package com.f3.aliothloud

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

/**
 * Re-attach after a reboot, but only if the user actually had it on. Starting a
 * foreground service unasked would be rude and would show a notification for a
 * feature that is switched off.
 *
 * The priv-app grant is double-checked here as well. If the module was removed
 * while the app was enabled, the effect can no longer touch other apps' audio,
 * so starting the service would just show a misleading notification. (The UI
 * also flushes the stale "on" state the next time it is opened.)
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                val s = Prefs(context).load()
                if (s.enabled && isPrivileged(context)) EngineService.start(context)
            }
        }
    }

    private fun isPrivileged(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(
            ctx, "android.permission.MODIFY_DEFAULT_AUDIO_EFFECTS"
        ) == PackageManager.PERMISSION_GRANTED
}
