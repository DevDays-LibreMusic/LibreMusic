package com.zarz.mornye

import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CancellationException

class AudioVersionModelStoreTest {
    private val directory = Files.createTempDirectory("audio-version-model-test").toFile()
    private val bytes = ByteArray(150000) { (it * 31).toByte() }
    private val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private val store = AudioVersionModelStore(File(directory, "models"), bytes.size.toLong(), sha)

    @After fun cleanup() { directory.deleteRecursively() }

    @Test fun validImportIsVerifiedAndCorruptionIsUnavailable() {
        assertNull(store.verifiedModel())
        store.import(ByteArrayInputStream(bytes))
        assertEquals(store.model, store.verifiedModel())
        store.import(ByteArrayInputStream(bytes))
        assertEquals(store.model, store.verifiedModel())
        store.model.writeBytes(ByteArray(bytes.size))
        assertNull(store.verifiedModel())
    }

    @Test fun invalidReplacementsRetainPreviousValidModelAndRemovePartialFiles() {
        store.import(ByteArrayInputStream(bytes))
        for (invalid in listOf(bytes.copyOf(bytes.size - 1), bytes + 1, ByteArray(bytes.size))) {
            try {
                store.import(ByteArrayInputStream(invalid))
                fail("Invalid model accepted")
            } catch (_: AudioVersionInvalidModel) { }
            assertArrayEquals(bytes, store.model.readBytes())
            assertEquals(listOf(store.model.name), store.model.parentFile!!.list()!!.toList())
        }
    }

    @Test fun cancellationAndReadFailureNeverPublishPartialModel() {
        store.import(ByteArrayInputStream(bytes))
        var checks = 0
        try {
            store.import(ByteArrayInputStream(bytes)) {
                if (++checks == 3) throw CancellationException()
            }
            fail("Cancelled import completed")
        } catch (_: CancellationException) { }
        val broken = object : InputStream() {
            override fun read(): Int = throw IOException("read failed")
        }
        try {
            store.import(broken)
            fail("Broken stream accepted")
        } catch (_: IOException) { }
        assertArrayEquals(bytes, store.model.readBytes())
        assertEquals(listOf(store.model.name), store.model.parentFile!!.list()!!.toList())
    }

    @Test fun separatePinnedModelsPublishWithoutReplacingEachOther() {
        store.import(ByteArrayInputStream(bytes))
        val demucs = AudioVersionModelStore(File(directory, "models"), bytes.size.toLong(), sha, "htdemucs-trunk-fp32.onnx")
        demucs.import(ByteArrayInputStream(bytes))
        assertNotEquals(store.model, demucs.model)
        assertNotNull(store.verifiedModel())
        assertNotNull(demucs.verifiedModel())
        demucs.model.writeBytes(ByteArray(bytes.size))
        assertNull(demucs.verifiedModel())
        assertNotNull(store.verifiedModel())
    }

    @Test fun freshStoreStreamsBothBundledModelsAndValidStoreNeverReopensAssets() {
        val secondBytes = bytes.reversedArray()
        val secondSha = MessageDigest.getInstance("SHA-256").digest(secondBytes).joinToString("") { "%02x".format(it) }
        val second = AudioVersionModelStore(File(directory, "models"), secondBytes.size.toLong(), secondSha, "htdemucs-trunk-fp32.onnx")
        var opened = 0
        fun asset(data: ByteArray): InputStream {
            opened++
            return object : ByteArrayInputStream(data) {
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    assertTrue("Model copy must remain streaming", length <= 64 * 1024)
                    return super.read(buffer, offset, length)
                }
            }
        }
        store.ensureBundled({ asset(bytes) })
        second.ensureBundled({ asset(secondBytes) })
        assertEquals(2, opened)
        assertArrayEquals(bytes, store.model.readBytes())
        assertArrayEquals(secondBytes, second.model.readBytes())
        store.ensureBundled({ fail("Valid model must not reopen asset"); error("unreachable") })
        second.ensureBundled({ fail("Valid model must not reopen asset"); error("unreachable") })
        assertEquals(2, opened)
    }

    @Test fun missingOrCorruptBundledAssetFailsClosedAndRetainsExistingFile() {
        store.model.parentFile!!.mkdirs()
        val previous = ByteArray(bytes.size) { 7 }
        store.model.writeBytes(previous)
        try {
            store.ensureBundled({ throw IOException("Missing bundled asset") })
            fail("Missing bundled asset accepted")
        } catch (_: IOException) { }
        assertArrayEquals(previous, store.model.readBytes())
        try {
            store.ensureBundled({ ByteArrayInputStream(ByteArray(bytes.size)) })
            fail("Corrupt bundled asset accepted")
        } catch (_: AudioVersionInvalidModel) { }
        assertNull(store.verifiedModel())
        assertArrayEquals(previous, store.model.readBytes())
        assertEquals(listOf(store.model.name), store.model.parentFile!!.list()!!.toList())
    }

    @Test fun cancelledBundledCopyRemovesPartialFileAndCanRetry() {
        store.model.parentFile!!.mkdirs()
        val previous = ByteArray(bytes.size) { 9 }
        store.model.writeBytes(previous)
        var transferred = 0
        val stream = object : ByteArrayInputStream(bytes) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                super.read(buffer, offset, length).also { if (it > 0) transferred += it }
        }
        try {
            store.ensureBundled({ stream }) {
                if (transferred >= 65536) throw CancellationException()
            }
            fail("Cancelled bundled copy completed")
        } catch (_: CancellationException) { }
        assertArrayEquals(previous, store.model.readBytes())
        assertEquals(listOf(store.model.name), store.model.parentFile!!.list()!!.toList())
        store.ensureBundled({ ByteArrayInputStream(bytes) })
        assertEquals(store.model, store.verifiedModel())
    }

    @Test fun clipBoundaryRejectsOutsideAndPrefixSiblingAndSymlinkEscape() {
        val root = File(directory, "cache").apply { mkdirs() }
        val outside = File(directory, "cache-other").apply { mkdirs() }
        val good = File(root, "good.f32").apply { writeBytes(ByteArray(192000 * 4)) }
        val bad = File(outside, "bad.f32").apply { writeBytes(ByteArray(192000 * 4)) }
        assertEquals(good.canonicalFile, audioVersionPrivateClip(good.path, listOf(root)))
        val short = File(root, "short.f32").apply { writeBytes(ByteArray(12)) }
        val symlink = File(root, "escape.f32")
        Files.createSymbolicLink(symlink.toPath(), bad.toPath())
        for (path in listOf(bad.path, symlink.path, short.path)) {
            try {
                audioVersionPrivateClip(path, listOf(root))
                fail("Outside clip accepted")
            } catch (_: IllegalArgumentException) { }
        }
    }
}
