package com.zarz.mornye

import ai.onnxruntime.*
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object AudioVersionDemucsContract {
    const val MODEL_ID = "htdemucs-trunk-fp32"
    const val MODEL_BYTES = 174263852L
    const val MODEL_SHA256 = "273be7e599749c71ef29b6f34c20721937c336aa85b3e1f2fde5b57a987f07ba"
    const val SEGMENT = 343980
    const val FRAMES = 336
    const val MODEL_FILENAME = "htdemucs-trunk-fp32.onnx"
}

/** The exact official HTDemucs real-valued trunk. Native code owns complex FFTs. */
internal object AudioVersionDemucsRuntime {
    private val inputs = mapOf(
        "normalized_stereo_samples" to longArrayOf(1, 2, 343980),
        "complex_spectrogram_channels" to longArrayOf(1, 4, 2048, 336),
    )
    private val outputs = mapOf(
        "source_complex_spectrogram_channels" to longArrayOf(1, 4, 4, 2048, 336),
        "source_time_branch" to longArrayOf(1, 4, 2, 343980),
    )
    fun checkShape(session: OrtSession) {
        require(session.inputNames == inputs.keys && session.outputNames == outputs.keys)
        for ((name, shape) in inputs + outputs) {
            val info = (session.inputInfo[name] ?: session.outputInfo[name])?.info as? TensorInfo
            require(info?.type == OnnxJavaType.FLOAT && info.shape.contentEquals(shape))
        }
    }
    private fun tensor(environment: OrtEnvironment, file: File, shape: LongArray, checkCancelled: () -> Unit): OnnxTensor {
        val count = shape.fold(1L) { a, b -> a * b }
        require(file.isFile && file.length() == count * 4)
        val buffer = ByteBuffer.allocateDirect((count * 4).toInt()).order(ByteOrder.nativeOrder())
        file.inputStream().channel.use { source ->
            while (buffer.hasRemaining()) {
                checkCancelled()
                check(source.read(buffer) >= 0) { "Truncated Demucs tensor" }
            }
        }
        if (ByteOrder.nativeOrder() != ByteOrder.LITTLE_ENDIAN) {
            buffer.flip()
            val little = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            while (little.hasRemaining()) buffer.putFloat(little.float)
        }
        val values = buffer.duplicate().apply { rewind() }.asFloatBuffer()
        while (values.hasRemaining()) require(values.get().isFinite())

        buffer.rewind()
        return OnnxTensor.createTensor(environment, buffer.asFloatBuffer(), shape)
    }
    private fun save(tensor: OnnxTensor, file: File, checkCancelled: () -> Unit) {
        val values = tensor.floatBuffer
        FileOutputStream(file).use { destination ->
            val buffer = ByteBuffer.allocate(65536).order(ByteOrder.LITTLE_ENDIAN)
            while (values.hasRemaining()) {
                checkCancelled()
                buffer.clear()
                while (buffer.remaining() >= 4 && values.hasRemaining()) {
                    val value = values.get()
                    require(value.isFinite())
                    buffer.putFloat(value)
                }
                destination.write(buffer.array(), 0, buffer.position())
            }
        }
    }
    fun runChunk(environment: OrtEnvironment, session: OrtSession, options: OrtSession.RunOptions,
                 waveFile: File, specFile: File, freqFile: File, timeFile: File, checkCancelled: () -> Unit) {
        checkCancelled()
        tensor(environment, waveFile, inputs.getValue("normalized_stereo_samples"), checkCancelled).use { wave ->
            tensor(environment, specFile, inputs.getValue("complex_spectrogram_channels"), checkCancelled).use { spec ->
                session.run(mapOf("normalized_stereo_samples" to wave, "complex_spectrogram_channels" to spec), options).use { result ->
                    checkCancelled()
                    save(result.get("source_complex_spectrogram_channels").get() as OnnxTensor, freqFile, checkCancelled)
                    save(result.get("source_time_branch").get() as OnnxTensor, timeFile, checkCancelled)
                }
            }
        }
        checkCancelled()
    }
}
