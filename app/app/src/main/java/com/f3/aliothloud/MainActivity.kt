package com.f3.aliothloud

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.slider.Slider

class MainActivity : AppCompatActivity() {

    private lateinit var prefs: Prefs
    private lateinit var settings: Settings
    private val engineProbe = LoudnessEngine()

    private lateinit var statusView: TextView
    private lateinit var availabilityView: TextView
    private lateinit var estimateView: TextView
    private lateinit var presetLabel: TextView
    private lateinit var presetGroup: ChipGroup
    private lateinit var footerView: TextView
    private lateinit var master: MaterialSwitch
    private lateinit var sliderHost: LinearLayout

    /** Guard so programmatic updates don't feed back into listeners. */
    private var suppress = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        prefs = Prefs(this)
        settings = prefs.load()

        statusView = findViewById(R.id.status)
        availabilityView = findViewById(R.id.availability)
        estimateView = findViewById(R.id.estimate)
        presetLabel = findViewById(R.id.presetLabel)
        presetGroup = findViewById(R.id.presets)
        footerView = findViewById(R.id.footer)
        master = findViewById(R.id.master)
        sliderHost = findViewById(R.id.sliders)

        // Everything below the master switch is only meaningful while
        // processing is on, so it dims and stops accepting touches when it is
        // off. Registered with its designed alpha so dimming is a scale of the
        // intended value rather than a flat override -- the help text is
        // already faint at 0.55 and must not end up brighter than its label.
        registerDimmable(estimateView, 1f)
        registerDimmable(presetLabel, 0.8f)
        registerDimmable(presetGroup, 1f)

        requestNotificationsIfNeeded()
        buildPresets()
        buildSliders()

        master.setOnCheckedChangeListener { _, on ->
            if (suppress) return@setOnCheckedChangeListener
            if (!isPrivileged()) {
                // Belt and braces: a disabled switch cannot be toggled, so this
                // only trips if the UI somehow races a priv-app change. Refuse
                // rather than start a chain that cannot work.
                suppress = true
                master.isChecked = false
                suppress = false
                return@setOnCheckedChangeListener
            }
            settings.enabled = on
            setControlsEnabled(on)
            persistAndPush(restart = true)
        }

        setControlsEnabled(settings.enabled)
        footerView.text = FOOTER
        // A switch that claims to boost audio but is physically unable to is
        // worse than none, so it is locked off until the module's priv-app grant
        // is actually present. Evaluate after the UI is built.
        applyPrivilegeGate()
    }

    override fun onResume() {
        super.onResume()
        // The module may have been installed or removed while this was paused.
        // If it was removed, the effect no longer works, so the master switch
        // is locked back off and any stale "on" state is flushed.
        applyPrivilegeGate()
    }

    // -----------------------------------------------------------------------
    // enable / disable
    // -----------------------------------------------------------------------

    private val dimmable = mutableListOf<Pair<View, Float>>()

    private fun registerDimmable(v: View, normalAlpha: Float) {
        dimmable += v to normalAlpha
    }

    /**
     * Grey out and lock every control below the master switch.
     *
     * Two separate things have to happen and neither is sufficient alone:
     * alpha makes it *look* unavailable, isEnabled makes it *be* unavailable.
     * Dimming without disabling would leave working sliders that look dead,
     * which is worse than no dimming at all.
     *
     * Chips are disabled individually. Disabling a ChipGroup does not propagate
     * to its children, so the group would still hand touches to live chips.
     */
    private fun setControlsEnabled(on: Boolean) {
        for ((v, normal) in dimmable) {
            v.alpha = if (on) normal else normal * DISABLED_ALPHA_SCALE
            v.isEnabled = on
        }
        for (i in 0 until presetGroup.childCount) {
            presetGroup.getChildAt(i).isEnabled = on
        }
        sliderViews.forEach { (_, slider) -> slider.isEnabled = on }
        updateLabels()
    }

    // -----------------------------------------------------------------------
    // presets
    // -----------------------------------------------------------------------

    private fun buildPresets() {
        Settings.PRESETS.forEach { (name, preset) ->
            val chip = Chip(this).apply {
                text = name
                isCheckable = true
                isChecked = name == prefs.presetName
                setOnClickListener {
                    prefs.presetName = name
                    // A preset defines the shape of the processing, not whether
                    // it runs. Picking one must not flip the master switch under
                    // the user, so the enabled flag is carried across.
                    val wasEnabled = settings.enabled
                    settings.copyFrom(preset)
                    settings.enabled = wasEnabled
                    rebuildSliderValues()
                    updatePresetLabel()
                    persistAndPush(restart = true)
                }
            }
            presetGroup.addView(chip)
        }
        updatePresetLabel()
    }

    /**
     * Once a slider is touched the values no longer match any preset, so no chip
     * should stay lit claiming otherwise. The header says "custom" instead.
     */
    private fun markCustom() {
        if (prefs.presetName.isEmpty()) return
        prefs.presetName = ""
        // clearCheck() only affects checked state; the chips' click listeners
        // are not invoked, so this cannot recurse back into markCustom().
        presetGroup.clearCheck()
        updatePresetLabel()
    }

    private fun updatePresetLabel() {
        presetLabel.text = if (prefs.presetName.isEmpty()) {
            "${getString(R.string.preset)}  \u00b7  ${getString(R.string.preset_custom).lowercase()}"
        } else {
            getString(R.string.preset)
        }
    }

    // -----------------------------------------------------------------------
    // sliders
    // -----------------------------------------------------------------------

    private class Spec(
        val label: String,
        val min: Float,
        val max: Float,
        val step: Float,
        val unit: String,
        val help: String,
        val get: (Settings) -> Float,
        val set: (Settings, Float) -> Unit
    )

    private val specs = listOf(
        Spec("Makeup gain", 0f, 24f, 1f, "dB",
            "Gain applied after compression. This is where the loudness comes from.",
            { it.makeupDb }, { s, v -> s.makeupDb = v }),
        Spec("Threshold", -60f, -6f, 1f, "dBFS",
            "Level above which compression starts. Lower squashes more of the signal.",
            { it.thresholdDb }, { s, v -> s.thresholdDb = v }),
        Spec("Ratio", 1f, 20f, 0.5f, ":1",
            "How hard the compressor pulls peaks down. 1 = off.",
            { it.ratio }, { s, v -> s.ratio = v }),
        Spec("Attack", 1f, 50f, 1f, "ms",
            "Faster catches transients but dulls percussion.",
            { it.attackMs }, { s, v -> s.attackMs = v }),
        Spec("Release", 20f, 400f, 10f, "ms",
            "Too fast causes pumping, too slow loses loudness between notes.",
            { it.releaseMs }, { s, v -> s.releaseMs = v }),
        Spec("Knee", 0f, 12f, 1f, "dB",
            "Softens the transition into compression.",
            { it.kneeDb }, { s, v -> s.kneeDb = v }),
        Spec("Limiter ceiling", -3f, 0f, 0.1f, "dBFS",
            "Hard output ceiling. Keep just under 0 so nothing clips.",
            { it.limiterCeilingDb }, { s, v -> s.limiterCeilingDb = v }),
        Spec("Flat gain", 0f, 1500f, 100f, "mB",
            "LoudnessEnhancer, applied on top. Blunt: no compression, clips easily.",
            { it.loudnessGainMb.toFloat() }, { s, v -> s.loudnessGainMb = v.toInt() })
    )

    private val sliderViews = mutableListOf<Pair<Spec, Slider>>()
    private val valueLabels = mutableListOf<TextView>()

    private fun buildSliders() {
        specs.forEach { spec ->
            val label = TextView(this).apply {
                textSize = 13f
                setPadding(0, dp(14), 0, 0)
            }
            val help = TextView(this).apply {
                text = spec.help
                textSize = 10f
                setPadding(0, 0, 0, dp(2))
            }
            val slider = Slider(this).apply {
                valueFrom = spec.min
                valueTo = spec.max
                stepSize = spec.step
                value = spec.get(settings).coerceIn(spec.min, spec.max)
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
                addOnChangeListener { _, v, fromUser ->
                    if (!fromUser || suppress) return@addOnChangeListener
                    spec.set(settings, v)
                    markCustom()
                    updateLabels()
                    // Live update, no teardown, so audio does not gap.
                    persistAndPush(restart = false)
                }
            }
            sliderHost.addView(label)
            sliderHost.addView(help)
            sliderHost.addView(slider)
            sliderViews += spec to slider
            valueLabels += label

            registerDimmable(label, 1f)
            registerDimmable(help, 0.55f)
        }
        updateLabels()
    }

    private fun rebuildSliderValues() {
        suppress = true
        sliderViews.forEach { (spec, slider) ->
            slider.value = spec.get(settings).coerceIn(spec.min, spec.max)
        }
        suppress = false
        updateLabels()
    }

    private fun updateLabels() {
        sliderViews.forEachIndexed { i, (spec, _) ->
            val v = spec.get(settings)
            val shown = if (spec.step >= 1f) "%.0f".format(v) else "%.1f".format(v)
            valueLabels[i].text = "${spec.label}:  $shown ${spec.unit}"
        }
        // Showing an estimated gain while processing is off would be a lie, so
        // the switch state is reflected here rather than only in the dimming.
        estimateView.text = if (settings.enabled) {
            "estimated  ~+%.0f dB perceived loudness".format(settings.estimatedLoudnessGainDb())
        } else {
            "processing off \u2014 stock output"
        }
    }

    // -----------------------------------------------------------------------

    private fun persistAndPush(restart: Boolean) {
        prefs.save(settings)
        if (settings.enabled) {
            if (restart) EngineService.start(this) else EngineService.reload(this)
        } else {
            EngineService.stop(this)
        }
        updateLabels()
        statusView.postDelayed({ refresh() }, 350)
    }

    private fun isPrivileged(): Boolean =
        ContextCompat.checkSelfPermission(
            this, "android.permission.MODIFY_DEFAULT_AUDIO_EFFECTS"
        ) == PackageManager.PERMISSION_GRANTED

    /**
     * The session-0 effect only reaches other apps' audio when this app holds
     * MODIFY_DEFAULT_AUDIO_EFFECTS, a signature|privileged permission that the
     * module grants by installing the app into /system/priv-app. Without it the
     * engine cannot boost anything but this app's own audio, so enabling the
     * master switch would promise loudness that never arrives. This gate keeps
     * the whole control block locked off until the grant exists.
     */
    private fun applyPrivilegeGate() {
        val privileged = isPrivileged()
        if (privileged) {
            master.isEnabled = true
            refresh()
            return
        }
        // Not privileged. Flush any persisted "on" so a stale enable cannot
        // resurface after a reboot, and stop a chain that would run in vain.
        suppress = true
        if (settings.enabled) {
            settings.enabled = false
            prefs.save(settings)
            EngineService.stop(this)
        }
        master.isChecked = false
        master.isEnabled = false
        suppress = false
        setControlsEnabled(false)
        refresh()
    }

    private fun refresh() {
        val r = EngineService.lastStatus
        val privileged = isPrivileged()

        statusView.text = buildString {
            append("privileged : ")
            append(if (privileged) "yes" else "NO  <-- module did not install as priv-app")
            append("\nengine     : ")
            append(if (settings.enabled) r.status.name else "off")
            if (r.detail.isNotEmpty() && settings.enabled) append("\ndetail     : ${r.detail}")
            if (!privileged && !master.isEnabled) {
                append("\naction     : install the module to enable the master switch")
            }
        }
        availabilityView.text = engineProbe.describeAvailability()
    }

    private fun requestNotificationsIfNeeded() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            runCatching {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
        }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        /**
         * Multiplier applied to a view's normal alpha when it is disabled.
         * Material's disabled opacity is 0.38 absolute; as a scale factor this
         * lands close to that for full-opacity views while keeping the already
         * faint help text below its own label.
         */
        private const val DISABLED_ALPHA_SCALE = 0.4f

        private val FOOTER = """
            Layers 1-2 of alioth-loud. This is the only part that can exceed the
            stock maximum volume: the module's curve layer cannot, because stock
            attenuation at volume index 100 is already 0 mB, and the probe found
            almost no hardware headroom left (EAR PA and Cirrus attenuator are
            already at their maxima, CS35L41 class-D is 18 of 20).

            Loudness here comes from compression, not raw gain. The limiter is
            always on, so large makeup gain raises the average level instead of
            clipping the peaks.

            Requires the module to have installed this app into /system/priv-app.
            If "privileged" reads NO, the effect can only process this app's own
            audio, which boosts nothing.
        """.trimIndent()
    }
}
