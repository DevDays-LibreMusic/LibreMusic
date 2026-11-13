package com.zarz.mornye

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

class AudioVersionClipMathTest {
    @Test fun syntheticWaveformMatchesExportNormalizationGolden() {
        val stream = javaClass.getResourceAsStream("/audio_version_wavlm_synthetic.json")!!
        val golden = stream.bufferedReader().use { JSONObject(it.readText()) }
        val a = FloatArray(192000) { index ->
            val i = index.toDouble()
            val u = ((1664525L * (index + 1) + 1013904223L) and 0xffffffffL).toDouble() / 4294967296.0
            (.15 * sin(2 * PI * 220 * i / 16000) +
                .1 * sin(2 * PI * 659.25 * i / 16000) + .025 * (2 * u - 1)).toFloat()
        }
        val b = FloatArray(a.size) { if (it in 81600 until 87200) 0f else a[it] * .7f }
        for ((role, raw) in listOf(a, b).withIndex()) {
            val normalized = AudioVersionClipMath.normalize(raw)
            val expected = golden.getJSONArray("cases").getJSONObject(role).getJSONArray("normalization_samples")
            for (i in 0 until expected.length()) {
                val sample = expected.getJSONObject(i)
                val index = sample.getInt("index")
                assertEquals(sample.getDouble("raw"), raw[index].toDouble(), 2e-7)
                assertEquals(sample.getDouble("normalized"), normalized[index].toDouble(), 1e-5)
            }
        }
    }

    @Test fun silenceIsFiniteAndDamagedPcmIsRejected() {
        assertTrue(AudioVersionClipMath.normalize(FloatArray(192000)).all { it == 0f })
        for (invalid in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            try {
                AudioVersionClipMath.normalize(FloatArray(192000).apply { this[1024] = invalid })
                fail("Non-finite PCM accepted")
            } catch (_: IllegalArgumentException) { }
        }
        try {
            AudioVersionClipMath.normalize(FloatArray(10))
            fail("Short clip accepted")
        } catch (_: IllegalArgumentException) { }
    }
}
