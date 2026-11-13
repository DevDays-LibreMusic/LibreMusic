package com.zarz.mornye

import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest

internal object AudioVersionWavlmContract {
    const val MODEL_ID = "wavlm-layer6-v9-fp32"
    const val MODEL_BYTES = 216152021L
    const val MODEL_SHA256 = "594a8aa0be7b036a14ac8b8d15e588b0f388295fbc026bc2acaed6ae983205eb"
    const val INPUT_SAMPLES = 192000
    const val OUTPUT_FRAMES = 599
    const val OUTPUT_CHANNELS = 768
    const val INPUT_NAME = "normalized_samples"
    const val OUTPUT_NAME = "layer6_hidden_states"
}

internal class AudioVersionInvalidModel : IllegalArgumentException("Unsupported or damaged analysis model")

/** Private, immutable published model; interrupted/invalid imports retain the previous model. */
internal class AudioVersionModelStore(
    private val directory: File,
    private val expectedBytes: Long = AudioVersionWavlmContract.MODEL_BYTES,
    private val expectedSha256: String = AudioVersionWavlmContract.MODEL_SHA256,
) {
    val model: File get() = File(directory, "wavlm-layer6-fp32.onnx")

    fun verifiedModel(checkCancelled: () -> Unit = {}): File? {
        if (!model.isFile || model.length() != expectedBytes) return null
        return model.takeIf {
            it.inputStream().use { source -> digest(source, checkCancelled).second == expectedSha256 }
        }
    }

    fun import(source: InputStream, checkCancelled: () -> Unit = {}): File {
        check(directory.isDirectory || directory.mkdirs()) { "Cannot create analysis model directory" }
        val temporary = File.createTempFile("wavlm-import-", ".part", directory)
        try {
            val hash = MessageDigest.getInstance("SHA-256")
            var count = 0L
            FileOutputStream(temporary).use { destination ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    checkCancelled()
                    val length = source.read(buffer)
                    if (length < 0) break
                    count += length
                    if (count > expectedBytes) throw AudioVersionInvalidModel()
                    hash.update(buffer, 0, length)
                    destination.write(buffer, 0, length)
                }
                if (count != expectedBytes || hex(hash.digest()) != expectedSha256) {
                    throw AudioVersionInvalidModel()
                }
                checkCancelled()
                destination.fd.sync()
            }
            checkCancelled()
            // Same-directory POSIX rename publishes atomically, including replacement.
            // Never delete the previous valid model as a rename fallback.
            check(temporary.renameTo(model)) { "Cannot publish analysis model" }
            return model
        } finally {
            temporary.delete()
        }
    }

    private fun digest(source: InputStream, checkCancelled: () -> Unit): Pair<Long, String> {
        val hash = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var count = 0L
        while (true) {
            checkCancelled()
            val length = source.read(buffer)
            if (length < 0) break
            count += length
            if (count > expectedBytes) throw AudioVersionInvalidModel()
            hash.update(buffer, 0, length)
        }
        checkCancelled()
        return count to hex(hash.digest())
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
}

internal object AudioVersionClipMath {
    /** Clip population variance; raw extraction padding must precede normalization. */
    fun normalize(raw: FloatArray): FloatArray {
        require(raw.size == AudioVersionWavlmContract.INPUT_SAMPLES) { "Expected a 12-second clip" }
        var sum = 0.0
        for (value in raw) {
            require(value.isFinite()) { "Non-finite PCM sample" }
            sum += value
        }
        val mean = (sum / raw.size).toFloat()
        var squared = 0.0
        for (value in raw) {
            val centered = value - mean
            squared += centered.toDouble() * centered
        }
        val variance = (squared / raw.size).toFloat()
        require(variance.isFinite()) { "PCM magnitude out of range" }
        val denominator = kotlin.math.sqrt(variance + 1e-7f)
        return FloatArray(raw.size) { (raw[it] - mean) / denominator }
    }
}

internal fun audioVersionPrivateClip(path: String, roots: List<File>): File {
    val file = File(path).canonicalFile
    require(file.isFile && roots.any {
        file.path.startsWith(it.canonicalPath + File.separator)
    }) { "Analysis input must be app-owned" }
    require(file.length() == AudioVersionWavlmContract.INPUT_SAMPLES * 4L)
    return file
}
