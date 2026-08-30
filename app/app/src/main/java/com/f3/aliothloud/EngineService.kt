package com.f3.aliothloud

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * Keeps the global effect chain alive.
 *
 * Two things kill a session-0 effect and both need handling:
 *
 *  1. The owning process dying. An AudioEffect is released when its owner goes
 *     away, so a plain Activity is not enough -- close the app and the boost
 *     disappears. Hence a foreground service.
 *
 *  2. audioserver restarting. When the media server dies, every AudioEffect
 *     handle becomes invalid and the effect is gone, but the objects in this
 *     process still look fine until touched.
 *
 * The clean way to catch (2) is AudioManager.setAudioServerStateCallback, but
 * that is @SystemApi and absent from android.jar, so using it would mean
 * reflecting into a hidden API. A poll is less elegant and completely reliable:
 * touching a dead effect throws IllegalStateException, which is an unambiguous
 * signal to rebuild. The check is a cheap getParameter, so a 10 s period costs
 * nothing measurable.
 */
class EngineService : Service() {

    companion object {
        private const val CHANNEL_ID = "alioth_loud_engine"
        private const val NOTIF_ID = 41
        private const val WATCHDOG_MS = 10_000L

        const val ACTION_START = "com.f3.aliothloud.START"
        const val ACTION_STOP = "com.f3.aliothloud.STOP"
        const val ACTION_RELOAD = "com.f3.aliothloud.RELOAD"

        /** Last status, so the UI can show why the chain is not running. */
        @Volatile var lastStatus: LoudnessEngine.Result =
            LoudnessEngine.Result(LoudnessEngine.Status.FAILED, "not started")
            private set

        fun start(ctx: Context) = send(ctx, ACTION_START)
        fun stop(ctx: Context) = send(ctx, ACTION_STOP)
        fun reload(ctx: Context) = send(ctx, ACTION_RELOAD)

        private fun send(ctx: Context, action: String) {
            val i = Intent(ctx, EngineService::class.java).setAction(action)
            try {
                ctx.startForegroundService(i)
            } catch (t: Throwable) {
                Log.w(LoudnessEngine.TAG, "startForegroundService failed: ${t.message}")
            }
        }
    }

    private val engine = LoudnessEngine()
    private lateinit var prefs: Prefs
    private val handler = Handler(Looper.getMainLooper())

    private val watchdog = object : Runnable {
        override fun run() {
            verifyAlive()
            handler.postDelayed(this, WATCHDOG_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                engine.detach()
                handler.removeCallbacks(watchdog)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RELOAD -> {
                // Slider moved: push values into the live effect. No teardown,
                // so there is no audible gap.
                val s = prefs.load()
                if (engine.isAttached) {
                    runCatching { engine.apply(s) }
                        .onFailure { attachNow(s) }   // stale handle, rebuild
                } else {
                    attachNow(s)
                }
            }
            else -> {
                goForeground("starting")
                attachNow(prefs.load())
                handler.removeCallbacks(watchdog)
                handler.postDelayed(watchdog, WATCHDOG_MS)
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(watchdog)
        engine.detach()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // -----------------------------------------------------------------------

    private fun attachNow(s: Settings) {
        val r = engine.attach(s)
        lastStatus = r
        Log.i(LoudnessEngine.TAG, "attach -> ${r.status}: ${r.detail}")
        goForeground(
            when (r.status) {
                LoudnessEngine.Status.OK ->
                    if (s.enabled) "active  ~+%.0f dB perceived".format(s.estimatedLoudnessGainDb())
                    else "attached, bypassed"
                LoudnessEngine.Status.NO_PERMISSION -> "not privileged - see app"
                LoudnessEngine.Status.UNSUPPORTED -> "effect unavailable"
                LoudnessEngine.Status.FAILED -> "failed - see app"
            }
        )
    }

    /**
     * Touch the effect. If audioserver restarted, the handle is stale and this
     * throws, which is the signal to rebuild the whole chain.
     */
    private fun verifyAlive() {
        if (!engine.isAttached) {
            val s = prefs.load()
            if (s.enabled) attachNow(s)
            return
        }
        val ok = runCatching { engine.apply(prefs.load()) }.isSuccess
        if (!ok) {
            Log.w(LoudnessEngine.TAG, "effect handle stale (audioserver restart?) - reattaching")
            engine.detach()
            attachNow(prefs.load())
        }
    }

    // -----------------------------------------------------------------------

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        val ch = NotificationChannel(
            CHANNEL_ID, "Loudness engine", NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "Keeps the global audio effect attached"
            setShowBadge(false)
        }
        nm.createNotificationChannel(ch)
    }

    private fun goForeground(text: String) {
        val tap = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val n: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Alioth Loud")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_silent_mode_off)
            .setContentIntent(tap)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= 34) {
            // targetSdk 35 requires a declared type. specialUse is the honest
            // one: this service plays nothing, it holds an effect handle.
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }
}
