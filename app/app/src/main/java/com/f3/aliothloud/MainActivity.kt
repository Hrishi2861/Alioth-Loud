package com.f3.aliothloud

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
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
        footerView = findViewById(R.id.footer)
        master = findViewById(R.id.master)
        sliderHost = findViewById(R.id.sliders)

        requestNotificationsIfNeeded()
        buildPresets(findViewById(R.id.presets))
        buildSliders()

        master.isChecked = settings.enabled
        master.setOnCheckedChangeListener { _, on ->
            if (suppress) return@setOnCheckedChangeListener
            settings.enabled = on
            persistAndPush(restart = true)
        }

        footerView.text = FOOTER
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    // -----------------------------------------------------------------------
    // presets
    // -----------------------------------------------------------------------

    private fun buildPresets(group: ChipGroup) {
        Settings.PRESETS.forEach { (name, preset) ->
            val chip = Chip(this).apply {
                text = name
                isCheckable = true
                isChecked = name == prefs.presetName
                setOnClickListener {
                    prefs.presetName = name
                    // Preserve the master switch: picking a preset should not
                    // silently turn processing on or off under the user.
                    val wasEnabled = settings.enabled
                    settings.copyFrom(preset)
                    settings.enabled = if (name == "Off") false else wasEnabled
                    suppress = true
                    master.isChecked = settings.enabled
                    suppress = false
                    rebuildSliderValues()
                    persistAndPush(restart = true)
                }
            }
            group.addView(chip)
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
                alpha = 0.55f
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
        estimateView.text =
            "estimated  ~+%.0f dB perceived loudness".format(settings.estimatedLoudnessGainDb())
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

    private fun refresh() {
        val r = EngineService.lastStatus
        val privileged = ContextCompat.checkSelfPermission(
            this, "android.permission.MODIFY_DEFAULT_AUDIO_EFFECTS"
        ) == PackageManager.PERMISSION_GRANTED

        statusView.text = buildString {
            append("privileged : ")
            append(if (privileged) "yes" else "NO  <-- module did not install as priv-app")
            append("\nengine     : ")
            append(if (settings.enabled) r.status.name else "off")
            if (r.detail.isNotEmpty() && settings.enabled) append("\ndetail     : ${r.detail}")
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
