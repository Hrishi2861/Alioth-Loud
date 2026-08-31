package com.f3.aliothloud

import android.content.Context

/**
 * Tunable state for the effect chain, plus presets.
 *
 * Units are whatever the Android API wants, so nothing has to be converted at
 * the call site: dB for gains and thresholds, milliseconds for envelopes,
 * millibels for LoudnessEnhancer (its API is mB, unlike everything else).
 */
data class Settings(
    var enabled: Boolean = false,

    /** Trim before the compressor. Negative leaves headroom into the chain. */
    var inputGainDb: Float = 0f,

    /**
     * Compressor threshold in dBFS. Everything above this gets compressed.
     * Lower = more of the signal compressed = louder average, more squash.
     */
    var thresholdDb: Float = -24f,

    /** Compression ratio. 1 = off. 4 is firm, 8+ is limiting territory. */
    var ratio: Float = 4f,

    /** Makeup gain applied per band AFTER compression. The loudness comes from here. */
    var makeupDb: Float = 9f,

    var attackMs: Float = 8f,
    var releaseMs: Float = 120f,

    /** Soft knee width in dB. Wider = less audible onset. */
    var kneeDb: Float = 6f,

    /**
     * Final ceiling in dBFS. Slightly below 0 so inter-sample peaks and the
     * downstream resampler do not clip.
     */
    var limiterCeilingDb: Float = -0.5f,

    /** Flat post-gain via LoudnessEnhancer, in MILLIbels. 0 disables it. */
    var loudnessGainMb: Int = 0
) {
    fun copyFrom(o: Settings) {
        enabled = o.enabled
        inputGainDb = o.inputGainDb
        thresholdDb = o.thresholdDb
        ratio = o.ratio
        makeupDb = o.makeupDb
        attackMs = o.attackMs
        releaseMs = o.releaseMs
        kneeDb = o.kneeDb
        limiterCeilingDb = o.limiterCeilingDb
        loudnessGainMb = o.loudnessGainMb
    }

    /**
     * Rough guide to how much louder this will sound, in dB of perceived
     * loudness. Not a measurement -- a heuristic so the UI can show something
     * honest instead of implying the makeup gain number is the whole story.
     *
     * Reasoning: makeup gain is only fully realised on material quiet enough to
     * sit under the threshold. Loud modern masters spend most of their time
     * above it, where the ratio decides how much of the gain survives.
     */
    fun estimatedLoudnessGainDb(): Float {
        val fromMakeup = makeupDb * (1f - 1f / ratio.coerceAtLeast(1f)).coerceIn(0f, 1f) + makeupDb * 0.35f
        val fromFlat = loudnessGainMb / 100f
        return (fromMakeup + fromFlat).coerceIn(0f, 30f)
    }

    companion object {
        /**
         * Curated presets. Names describe the tradeoff, not a marketing tier.
         *
         * There is deliberately no "Off" preset. On/off belongs to the master
         * switch, which also greys these out, so an "Off" chip would be both a
         * second control for the same state and unreachable at the moment it
         * would be needed. The [enabled] field of each preset below is ignored
         * for the same reason: applying a preset carries the current switch
         * state across rather than overriding it.
         */
        val PRESETS: Map<String, Settings> = linkedMapOf(
            // Barely-there dynamics control. Useful to verify the chain is
            // attached without changing the character of anything.
            "Transparent" to Settings(
                enabled = true, thresholdDb = -18f, ratio = 2f, makeupDb = 3f,
                attackMs = 15f, releaseMs = 200f, kneeDb = 8f, limiterCeilingDb = -1f
            ),

            // The sensible default. Clearly louder, still sounds like music.
            "Loud" to Settings(
                enabled = true, thresholdDb = -24f, ratio = 4f, makeupDb = 9f,
                attackMs = 8f, releaseMs = 120f, kneeDb = 6f, limiterCeilingDb = -0.5f
            ),

            // Aggressive. Noticeable pumping on dynamic material, but this is
            // the setting that answers "max volume is not loud enough".
            "Very loud" to Settings(
                enabled = true, thresholdDb = -32f, ratio = 8f, makeupDb = 14f,
                attackMs = 4f, releaseMs = 90f, kneeDb = 4f, limiterCeilingDb = -0.3f
            ),

            // Everything the chain has. Heavily compressed, obvious artifacts on
            // music, genuinely useful for quiet voice recordings and speakerphone.
            "Maximum" to Settings(
                enabled = true, thresholdDb = -40f, ratio = 12f, makeupDb = 18f,
                attackMs = 2f, releaseMs = 70f, kneeDb = 2f, limiterCeilingDb = -0.2f,
                loudnessGainMb = 300
            ),

            // Speech-tuned: fast envelope, hard compression, no flat gain.
            "Voice / podcast" to Settings(
                enabled = true, thresholdDb = -34f, ratio = 10f, makeupDb = 13f,
                attackMs = 3f, releaseMs = 60f, kneeDb = 3f, limiterCeilingDb = -0.5f
            )
        )
    }
}

/** SharedPreferences persistence. Small enough that a schema is overkill. */
class Prefs(ctx: Context) {
    private val sp = ctx.getSharedPreferences("alioth_loud", Context.MODE_PRIVATE)

    fun load(): Settings = Settings(
        enabled = sp.getBoolean("enabled", false),
        inputGainDb = sp.getFloat("inputGainDb", 0f),
        thresholdDb = sp.getFloat("thresholdDb", -24f),
        ratio = sp.getFloat("ratio", 4f),
        makeupDb = sp.getFloat("makeupDb", 9f),
        attackMs = sp.getFloat("attackMs", 8f),
        releaseMs = sp.getFloat("releaseMs", 120f),
        kneeDb = sp.getFloat("kneeDb", 6f),
        limiterCeilingDb = sp.getFloat("limiterCeilingDb", -0.5f),
        loudnessGainMb = sp.getInt("loudnessGainMb", 0)
    )

    fun save(s: Settings) = sp.edit().apply {
        putBoolean("enabled", s.enabled)
        putFloat("inputGainDb", s.inputGainDb)
        putFloat("thresholdDb", s.thresholdDb)
        putFloat("ratio", s.ratio)
        putFloat("makeupDb", s.makeupDb)
        putFloat("attackMs", s.attackMs)
        putFloat("releaseMs", s.releaseMs)
        putFloat("kneeDb", s.kneeDb)
        putFloat("limiterCeilingDb", s.limiterCeilingDb)
        putInt("loudnessGainMb", s.loudnessGainMb)
    }.apply()

    var presetName: String
        get() = sp.getString("preset", "Loud") ?: "Loud"
        set(v) = sp.edit().putString("preset", v).apply()
}
