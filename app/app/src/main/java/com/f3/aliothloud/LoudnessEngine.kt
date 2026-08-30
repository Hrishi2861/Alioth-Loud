package com.f3.aliothloud

import android.media.audiofx.AudioEffect
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.LoudnessEnhancer
import android.util.Log

/**
 * Layers 1 and 2: the only part of alioth-loud that can exceed the stock
 * maximum volume.
 *
 * Why this exists at all
 * ---------------------
 * The module's volume-curve layer rewrites attenuation values, and stock
 * attenuation at volume index 100 is already 0 mB. There is nothing to reclaim
 * at max volume, so no amount of XML editing raises the ceiling. The probe also
 * showed there is almost no hardware headroom left on this device: EAR PA Gain
 * and Cirrus SP Volume Attenuation are already at their enum maxima and the
 * CS35L41 class-D stage sits at 18 of 20. Roughly 1-2 dB remains in hardware.
 *
 * So perceived loudness has to come from dynamic range compression: pull the
 * quiet parts up, hold the peaks with a limiter, and the average level (what
 * you actually hear as "loud") rises 10-15 dB without ever exceeding 0 dBFS.
 * That is what ViPER4Android's chain does, and it is what DynamicsProcessing
 * does natively here.
 *
 * Why DynamicsProcessing rather than shipping a .so
 * -------------------------------------------------
 * It is a framework effect. No library in /vendor/lib/soundfx, no
 * audio_effects.xml patching, no SELinux label to get right, nothing for an OTA
 * to revert, and it is unaffected by the Android 15 AIDL effect-HAL transition
 * that is currently breaking V4A. The probe confirmed libdynproc.so is present
 * and registered with the standard AOSP UUID, and that the vendor <postprocess>
 * chain holds only volume-listener helpers, so there is no vendor effect to
 * fight for the output mix.
 *
 * Session 0
 * ---------
 * Attaching to AUDIO_SESSION_OUTPUT_MIX (0) makes the effect global. AudioFlinger
 * gates that behind MODIFY_DEFAULT_AUDIO_EFFECTS, which is signature|privileged,
 * so the app only works when the module has installed it into /system/priv-app
 * with a matching privapp-permissions entry. Without that, construction throws
 * and [attach] reports [Status.NO_PERMISSION] instead of silently processing
 * only this app's own audio.
 */
class LoudnessEngine {

    companion object {
        const val TAG = "AliothLoud"

        /** AUDIO_SESSION_OUTPUT_MIX. Global output mix. */
        const val GLOBAL_SESSION = 0

        /** Effects are cooperative; higher priority wins ties in the chain. */
        private const val PRIORITY = 0

        /** Stereo. getChannelCount() is re-read after construction anyway. */
        private const val ASSUMED_CHANNELS = 2

        /**
         * Four bands is a deliberate compromise. More bands means finer control
         * but more CPU in the audio path and more chance of audible inter-band
         * phase artifacts on a phone speaker. The crossovers below split roughly
         * into: sub/low (what the speaker cannot reproduce), low-mid (body),
         * presence (where perceived loudness mostly lives), and highs.
         */
        private const val MBC_BANDS = 4
        private val BAND_CUTOFFS = floatArrayOf(220f, 1000f, 4000f, 12000f)
    }

    enum class Status { OK, NO_PERMISSION, UNSUPPORTED, FAILED }

    data class Result(val status: Status, val detail: String = "")

    private var dp: DynamicsProcessing? = null
    private var le: LoudnessEnhancer? = null
    private var channels = ASSUMED_CHANNELS

    val isAttached: Boolean get() = dp != null || le != null

    /** Last error text, for surfacing in the UI instead of a silent no-op. */
    var lastError: String? = null
        private set

    // -----------------------------------------------------------------------
    // attach / detach
    // -----------------------------------------------------------------------

    fun attach(s: Settings): Result {
        detach()
        lastError = null

        val cfg = try {
            buildConfig(s)
        } catch (t: Throwable) {
            return fail("could not build config", t)
        }

        try {
            dp = DynamicsProcessing(PRIORITY, GLOBAL_SESSION, cfg)
            channels = dp?.channelCount ?: ASSUMED_CHANNELS
            Log.i(TAG, "DynamicsProcessing attached to session 0, $channels channels")
        } catch (t: Throwable) {
            // The distinction matters: an UnsupportedOperationException or a
            // RuntimeException mentioning permission means the priv-app install
            // did not take effect, which is a completely different fix from the
            // effect being absent.
            val why = t.message ?: t.javaClass.simpleName
            detach()
            return if (looksLikePermission(t)) {
                Result(
                    Status.NO_PERMISSION,
                    "MODIFY_DEFAULT_AUDIO_EFFECTS denied. The app must be installed " +
                        "by the module into /system/priv-app with a matching " +
                        "privapp-permissions entry. ($why)"
                )
            } else {
                Result(Status.UNSUPPORTED, "DynamicsProcessing unavailable: $why")
            }
        }

        // LoudnessEnhancer is a second, much blunter gain stage. It is optional
        // because the MBC's postGain already provides makeup gain; this is here
        // for the case where someone wants flat gain without more compression.
        if (s.loudnessGainMb > 0) {
            try {
                le = LoudnessEnhancer(GLOBAL_SESSION).apply {
                    setTargetGain(s.loudnessGainMb)
                    enabled = true
                }
                Log.i(TAG, "LoudnessEnhancer attached at ${s.loudnessGainMb} mB")
            } catch (t: Throwable) {
                // Non-fatal: the compressor is the important half.
                Log.w(TAG, "LoudnessEnhancer unavailable: ${t.message}")
                le = null
            }
        }

        return try {
            apply(s)
            Result(Status.OK, "attached, $channels ch")
        } catch (t: Throwable) {
            fail("attached but could not apply settings", t)
        }
    }

    fun detach() {
        try { dp?.enabled = false } catch (_: Throwable) {}
        try { dp?.release() } catch (_: Throwable) {}
        try { le?.enabled = false } catch (_: Throwable) {}
        try { le?.release() } catch (_: Throwable) {}
        dp = null
        le = null
    }

    // -----------------------------------------------------------------------
    // live parameter updates
    // -----------------------------------------------------------------------

    /**
     * Push [s] into the running effect without tearing it down, so dragging a
     * slider does not cause an audible gap.
     */
    fun apply(s: Settings) {
        val d = dp ?: return

        for (ch in 0 until channels) {
            // Input trim runs before everything else. Note the method name:
            // setInputGainbyChannel, lowercase 'b' and no "Index" suffix. That
            // is the actual AOSP signature, verified against android.jar.
            d.setInputGainbyChannel(ch, s.inputGainDb)

            for (b in 0 until MBC_BANDS) {
                val band = DynamicsProcessing.MbcBand(
                    /* enabled            */ true,
                    /* cutoffFrequency    */ BAND_CUTOFFS[b],
                    /* attackTime ms      */ s.attackMs,
                    /* releaseTime ms     */ s.releaseMs,
                    /* ratio              */ s.ratio,
                    /* threshold dBFS     */ s.thresholdDb,
                    /* kneeWidth dB       */ s.kneeDb,
                    /* noiseGateThreshold */ NOISE_GATE_DB,
                    /* expanderRatio      */ 1f,
                    /* preGain dB         */ 0f,
                    /* postGain dB        */ s.makeupDb
                )
                d.setMbcBandByChannelIndex(ch, b, band)
            }

            // Always-on limiter. This is what makes large makeup gain safe:
            // the compressor raises the average level, the limiter guarantees
            // the peaks never pass the ceiling. Without it, makeup gain above a
            // few dB just clips.
            val limiter = DynamicsProcessing.Limiter(
                /* inUse      */ true,
                /* enabled    */ true,
                /* linkGroup  */ 0,          // link channels so stereo image holds
                /* attackTime */ 1f,
                /* releaseTime*/ 60f,
                /* ratio      */ 20f,
                /* threshold  */ s.limiterCeilingDb,
                /* postGain   */ 0f
            )
            d.setLimiterByChannelIndex(ch, limiter)
        }

        d.enabled = s.enabled

        le?.let {
            try {
                it.setTargetGain(s.loudnessGainMb)
                it.enabled = s.enabled && s.loudnessGainMb > 0
            } catch (t: Throwable) {
                Log.w(TAG, "LoudnessEnhancer update failed: ${t.message}")
            }
        }
    }

    // -----------------------------------------------------------------------
    // config
    // -----------------------------------------------------------------------

    private fun buildConfig(s: Settings): DynamicsProcessing.Config {
        val b = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            ASSUMED_CHANNELS,
            /* preEqInUse     */ false, /* preEqBandCount  */ 0,
            /* mbcInUse       */ true,  /* mbcBandCount    */ MBC_BANDS,
            /* postEqInUse    */ false, /* postEqBandCount */ 0,
            /* limiterInUse   */ true
        )
        // 10 ms is a request, not a guarantee; the effect may round it. Shorter
        // means tighter peak control at higher CPU cost.
        b.setPreferredFrameDuration(10f)
        b.setInputGainAllChannelsTo(s.inputGainDb)
        return b.build()
    }

    private fun looksLikePermission(t: Throwable): Boolean {
        if (t is UnsupportedOperationException) return true
        val m = (t.message ?: "").lowercase()
        return "permission" in m || "denied" in m || "not permitted" in m
    }

    private fun fail(what: String, t: Throwable): Result {
        val why = "$what: ${t.message ?: t.javaClass.simpleName}"
        Log.e(TAG, why, t)
        lastError = why
        detach()
        return Result(Status.FAILED, why)
    }

    /**
     * Is the effect actually registered on this ROM? Answers "is it even
     * possible" separately from "did attaching work", so the UI can tell the
     * user which problem they have.
     */
    fun describeAvailability(): String {
        val want = mapOf(
            "dynamics_processing" to AudioEffect.EFFECT_TYPE_DYNAMICS_PROCESSING,
            "loudness_enhancer" to AudioEffect.EFFECT_TYPE_LOUDNESS_ENHANCER
        )
        val found = mutableListOf<String>()
        val missing = mutableListOf<String>()
        val descriptors = try {
            AudioEffect.queryEffects() ?: emptyArray()
        } catch (t: Throwable) {
            return "could not query effects: ${t.message}"
        }
        for ((label, uuid) in want) {
            if (descriptors.any { it.type == uuid }) found += label else missing += label
        }
        return buildString {
            append("present: ${found.joinToString(", ").ifEmpty { "none" }}")
            if (missing.isNotEmpty()) append("  |  MISSING: ${missing.joinToString(", ")}")
        }
    }
}

/** Below this input level the compressor stops working, so hiss is not pumped up. */
private const val NOISE_GATE_DB = -90f
