package com.zarz.mornye

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class NativeFlacConversionTest {
    private fun withFiles(block: (File, File) -> Unit) {
        val directory = Files.createTempDirectory("native-flac-conversion-").toFile()
        try {
            val input = File(directory, "input.m4a").apply { writeText("original audio") }
            block(input, File(directory, "output.partial.flac"))
            assertEquals("original audio", input.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun writeFlacHeader(file: File) {
        file.writeBytes(byteArrayOf(0x66, 0x4c, 0x61, 0x43) + ByteArray(64))
    }

    @Test
    fun validRemuxSkipsEncoderAndLeavesSourceUntouched() = withFiles { input, output ->
        val commands = mutableListOf<List<String>>()
        convertToStagedFlac(input.path, output.path, "flac", { arguments ->
            commands.add(arguments.toList())
            if ("copy" in arguments) writeFlacHeader(output)
            true to ""
        }, {})
        assertEquals(2, commands.size)
        assertTrue("copy" in commands.first())
        assertFalse("-map" in commands.first())
        assertTrue("null" in commands.last())
        assertFalse("-frames:a" in commands.last())
        assertFalse(commands.any { "-compression_level" in it })
        assertTrue(output.exists())
    }

    @Test
    fun failedRemuxOrValidationRetriesEncoderWithCleanStage() {
        for (failure in listOf("command", "header", "decode")) {
            withFiles { input, output ->
                var encoded = false
                convertToStagedFlac(input.path, output.path, "flac", { arguments ->
                    when {
                        "copy" in arguments -> {
                            if (failure == "header") output.writeText("invalid FLAC") else writeFlacHeader(output)
                            (failure != "command") to "remux diagnostic"
                        }
                        "-compression_level" in arguments -> {
                            assertFalse(output.exists())
                            encoded = true
                            writeFlacHeader(output)
                            true to ""
                        }
                        else -> (encoded || failure != "decode") to "decode diagnostic"
                    }
                }, {})
                assertTrue(encoded)
                assertTrue(output.exists())
            }
        }
    }

    @Test
    fun nonFlacSkipsRemuxAndFailedEncodeRemovesPartialOutput() = withFiles { input, output ->
        var calls = 0
        assertThrows(IllegalStateException::class.java) {
            convertToStagedFlac(input.path, output.path, "alac", { arguments ->
                calls++
                assertFalse("copy" in arguments)
                output.writeText("partial")
                false to "encoder failed"
            }, {})
        }
        assertEquals(1, calls)
        assertFalse(output.exists())
    }

    @Test
    fun cancellationAfterRemuxDoesNotFallbackAndRemovesPartialOutput() = withFiles { input, output ->
        var cancelled = false
        var calls = 0
        assertThrows(CancellationException::class.java) {
            convertToStagedFlac(input.path, output.path, "flac", {
                calls++
                writeFlacHeader(output)
                cancelled = true
                false to "cancelled"
            }, {
                if (cancelled) throw CancellationException()
            })
        }
        assertEquals(1, calls)
        assertFalse(output.exists())
    }

    @Test
    fun hostFlacInMp4RemuxAndFallbackPreserveDecodedPcmAndArtwork() {
        val ffmpeg = System.getenv("MORNYE_TEST_FFMPEG").orEmpty()
        assumeTrue(
            "Set MORNYE_TEST_FFMPEG for host media fixtures",
            File(ffmpeg).isFile && File(ffmpeg).canExecute(),
        )
        fun execute(arguments: Array<String>): Pair<Boolean, String> {
            val process = ProcessBuilder(listOf(ffmpeg) + arguments).redirectErrorStream(true).start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            return (process.waitFor() == 0) to output
        }
        fun run(vararg arguments: String): String {
            val result = execute(arrayOf(*arguments))
            assertTrue(result.second, result.first)
            return result.second.trim()
        }
        val directory = Files.createTempDirectory("native-flac-fixture-").toFile()
        try {
            val cover = File(directory, "cover.png")
            run("-v", "error", "-f", "lavfi", "-i", "color=c=red:s=32x32", "-frames:v", "1", cover.path)
            val coverHash = run("-v", "error", "-i", cover.path, "-map", "0:v:0", "-f", "hash", "-hash", "sha256", "-")
            for ((sampleRate, sampleFormat) in listOf(44100 to "s16", 96000 to "s32")) {
                val source = File(directory, "source-$sampleRate.flac")
                val input = File(directory, "input-$sampleRate.m4a")
                run(
                    "-v", "error", "-f", "lavfi", "-i", "aevalsrc=0.1*sin(2*PI*997*t):s=$sampleRate",
                    "-t", "0.2", "-c:a", "flac", "-sample_fmt", sampleFormat, source.path,
                )
                run(
                    "-v", "error", "-i", source.path, "-i", cover.path, "-map", "0:a:0", "-map", "1:v:0",
                    "-c", "copy", "-disposition:v", "attached_pic", "-strict", "-2", "-f", "mp4", input.path,
                )
                val sourceHash = run("-v", "error", "-i", source.path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "hash", "-hash", "sha256", "-")
                for (mode in listOf("remux", "failed-remux", "corrupt-remux")) {
                    val output = File(directory, "output-$sampleRate-$mode.partial.flac")
                    var encoded = false
                    convertToStagedFlac(input.path, output.path, "flac", { arguments ->
                        if ("-compression_level" in arguments) encoded = true
                        if (mode == "failed-remux" && "copy" in arguments) {
                            false to "forced remux failure"
                        } else {
                            execute(arguments).also { result ->
                                if (mode == "corrupt-remux" && "copy" in arguments && result.first) {
                                    val bytes = output.readBytes()
                                    // Keep metadata and the frame header intact, but use a
                                    // reserved subframe type. Tail-byte flips can change PCM
                                    // without causing a fatal decode error on older FFmpeg.
                                    var frame = 4
                                    do {
                                        val last = bytes[frame].toInt() and 0x80 != 0
                                        val length = ((bytes[frame + 1].toInt() and 0xff) shl 16) or
                                            ((bytes[frame + 2].toInt() and 0xff) shl 8) or
                                            (bytes[frame + 3].toInt() and 0xff)
                                        frame += 4 + length
                                    } while (!last)
                                    assertEquals(0xff, bytes[frame].toInt() and 0xff)
                                    assertEquals(0xf8, bytes[frame + 1].toInt() and 0xfe)
                                    val blockSizeCode = (bytes[frame + 2].toInt() and 0xff) shr 4
                                    val sampleRateCode = bytes[frame + 2].toInt() and 0x0f
                                    val numberPrefix = bytes[frame + 4].toInt() and 0xff
                                    var numberBytes = 0
                                    var mask = 0x80
                                    while (numberPrefix and mask != 0 && mask != 0) {
                                        numberBytes++
                                        mask = mask shr 1
                                    }
                                    var subframe = frame + 4 + maxOf(1, numberBytes)
                                    subframe += when (blockSizeCode) { 6 -> 1; 7 -> 2; else -> 0 }
                                    subframe += when (sampleRateCode) { 12 -> 1; 13, 14 -> 2; else -> 0 }
                                    subframe++ // Frame-header CRC-8.
                                    bytes[subframe] = 0x04 // Reserved subframe type 2.
                                    output.writeBytes(bytes)
                                    val validation = execute(arrayOf(
                                        "-v", "error", "-xerror", "-err_detect", "crccheck+explode",
                                        "-i", output.path, "-map", "0:a:0", "-f", "null", "-",
                                    ))
                                    assertFalse("$sampleRate Hz fixture must fail decoding: ${validation.second}", validation.first)
                                }
                            }
                        }
                    }, {})
                    // Host FFmpeg versions may reject an otherwise valid MP4
                    // remux. Both paths must preserve PCM and artwork; the
                    // mocked validRemux test verifies skipping the encoder.
                    if (mode != "remux") {
                        assertTrue("$sampleRate Hz $mode must retry encoding", encoded)
                    }
                    assertEquals(sourceHash, run("-v", "error", "-i", output.path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "hash", "-hash", "sha256", "-"))
                    assertEquals(coverHash, run("-v", "error", "-i", output.path, "-map", "0:v:0", "-f", "hash", "-hash", "sha256", "-"))
                    assertTrue(input.exists())
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }
}
