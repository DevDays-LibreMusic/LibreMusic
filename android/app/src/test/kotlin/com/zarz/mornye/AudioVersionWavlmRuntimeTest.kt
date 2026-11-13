package com.zarz.mornye

import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlin.math.PI
import kotlin.math.sin

/**
 * Optional real-model host test: run with desktop ORT and MORNYE_WAVLM_MODEL.
 * No model/audio binary is bundled into tests or the APK. Android JNI/device
 * validation remains separate; default host unit runs skip this expensive test.
 */
class AudioVersionWavlmRuntimeTest {
    @Test fun exportedModelMatchesSyntheticGoldenThroughProductionNumericPath() {
        val path = System.getenv("MORNYE_WAVLM_MODEL")
        assumeTrue("Set MORNYE_WAVLM_MODEL for real inference", !path.isNullOrBlank())
        val model = File(path!!)
        assumeTrue("External model is required", model.isFile)
        val fixture = javaClass.getResourceAsStream("/audio_version_wavlm_synthetic.json")!!
            .bufferedReader().use { JSONObject(it.readText()) }
        val a = FloatArray(192000) { index ->
            val i = index.toDouble()
            val u = ((1664525L * (index + 1) + 1013904223L) and 0xffffffffL).toDouble() / 4294967296.0
            (.15 * sin(2 * PI * 220 * i / 16000) +
                .1 * sin(2 * PI * 659.25 * i / 16000) + .025 * (2 * u - 1)).toFloat()
        }
        val b = FloatArray(a.size) { if (it in 81600 until 87200) 0f else a[it] * .7f }
        val directory = Files.createTempDirectory("wavlm-runtime-golden").toFile()
        try {
            val environment = OrtEnvironment.getEnvironment()
            AudioVersionWavlmRuntime.sessionOptions().use { options ->
                environment.createSession(model.path, options).use { session ->
                    AudioVersionWavlmRuntime.checkShape(session)
                    OrtSession.RunOptions().use { run ->
                        for ((index, raw) in listOf(a, b).withIndex()) {
                            val output = File(directory, "$index.f32le")
                            AudioVersionWavlmRuntime.runClip(environment, session, run, raw, output) { }
                            assertEquals(599L * 768 * 4, output.length())
                            val embeddings = ByteBuffer.wrap(output.readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                            val expected = fixture.getJSONArray("cases").getJSONObject(index).getJSONArray("selected_embeddings")
                            for (e in 0 until expected.length()) {
                                val frame = expected.getJSONObject(e)
                                val channels = frame.getJSONArray("channels")
                                val values = frame.getJSONArray("values")
                                for (c in 0 until channels.length()) {
                                    val offset = frame.getInt("frame") * 768 + channels.getInt(c)
                                    assertEquals(values.getDouble(c), embeddings.get(offset).toDouble(), 3e-4)
                                }
                            }
                        }
                    }
                    OrtSession.RunOptions().use { terminated ->
                        terminated.setTerminate(true)
                        val output = File(directory, "cancelled.f32le")
                        try {
                            AudioVersionWavlmRuntime.runClip(environment, session, terminated, a, output) { }
                            fail("Terminated inference produced output")
                        } catch (_: OrtException) { }
                        assertFalse(output.exists())
                    }
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }
}
