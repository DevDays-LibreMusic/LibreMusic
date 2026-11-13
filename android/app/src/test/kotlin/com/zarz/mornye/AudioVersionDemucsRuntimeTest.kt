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

/** Optional actual-model JVM test. Model is user supplied and never enters APK/test resources. */
class AudioVersionDemucsRuntimeTest {
    @Test fun realTrunkMatchesPythonOrtGoldenAndHonorsTermination() {
        val path = System.getenv("MORNYE_DEMUCS_MODEL")
        assumeTrue("Set MORNYE_DEMUCS_MODEL for actual model inference", !path.isNullOrBlank())
        val directory = Files.createTempDirectory("demucs-runtime-golden").toFile()
        try {
            val wave = File(directory, "wave").apply { writeBytes(ByteArray(2 * 343980 * 4)) }
            val spec = File(directory, "spec").apply { writeBytes(ByteArray(4 * 2048 * 336 * 4)) }
            val frequency = File(directory, "frequency")
            val time = File(directory, "time")
            val fixture = javaClass.getResourceAsStream("/audio_version_demucs_synthetic.json")!!
                .bufferedReader().use { JSONObject(it.readText()) }
            val environment = OrtEnvironment.getEnvironment()
            AudioVersionWavlmRuntime.sessionOptions().use { options ->
                environment.createSession(path!!, options).use { session ->
                    AudioVersionDemucsRuntime.checkShape(session)
                    OrtSession.RunOptions().use { run ->
                        AudioVersionDemucsRuntime.runChunk(environment, session, run, wave, spec, frequency, time) { }
                    }
                    assertEquals(4L * 4 * 2048 * 336 * 4, frequency.length())
                    assertEquals(4L * 2 * 343980 * 4, time.length())
                    for ((name, file) in listOf("frequency" to frequency, "time" to time)) {
                        val values = ByteBuffer.wrap(file.readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                        val expected = fixture.getJSONArray(name)
                        for (i in 0 until expected.length()) {
                            val point = expected.getJSONObject(i)
                            assertEquals(point.getDouble("value"), values.get(point.getInt("index")).toDouble(), 3e-5)
                        }
                    }
                    frequency.delete(); time.delete()
                    OrtSession.RunOptions().use { terminated ->
                        terminated.setTerminate(true)
                        try {
                            AudioVersionDemucsRuntime.runChunk(environment, session, terminated, wave, spec, frequency, time) { }
                            fail("Terminated Demucs produced output")
                        } catch (_: OrtException) { }
                    }
                    assertFalse(frequency.exists()); assertFalse(time.exists())
                }
            }
        } finally { directory.deleteRecursively() }
    }
}
