package com.zarz.mornye

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Pure JVM/ORT numeric path, shared by the Android bridge and host golden tests. */
internal object AudioVersionWavlmRuntime {
    fun sessionOptions(): OrtSession.SessionOptions = OrtSession.SessionOptions().apply {
        setIntraOpNumThreads(2)
        setInterOpNumThreads(1)
        setExecutionMode(OrtSession.SessionOptions.ExecutionMode.SEQUENTIAL)
        // Avoid retaining large per-context arenas or selecting an accelerator implicitly.
        setCPUArenaAllocator(false)
        setMemoryPatternOptimization(false)
        addConfigEntry("session.disable_prepacking", "1")
    }

    fun checkShape(session: OrtSession) {
        require(session.inputNames == setOf(AudioVersionWavlmContract.INPUT_NAME))
        require(session.outputNames == setOf(AudioVersionWavlmContract.OUTPUT_NAME))
        val input = session.inputInfo[AudioVersionWavlmContract.INPUT_NAME]?.info as? TensorInfo
        val output = session.outputInfo[AudioVersionWavlmContract.OUTPUT_NAME]?.info as? TensorInfo
        require(input?.type == OnnxJavaType.FLOAT && input.shape.contentEquals(longArrayOf(1, 192000)))
        require(output?.type == OnnxJavaType.FLOAT && output.shape.contentEquals(longArrayOf(1, 599, 768)))
    }

    fun runClip(
        environment: OrtEnvironment,
        session: OrtSession,
        options: OrtSession.RunOptions,
        raw: FloatArray,
        destination: File,
        checkCancelled: () -> Unit,
    ) {
        checkCancelled()
        val normalized = AudioVersionClipMath.normalize(raw)
        checkCancelled()
        val input = ByteBuffer.allocateDirect(normalized.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        input.put(normalized).rewind()
        OnnxTensor.createTensor(environment, input, longArrayOf(1, 192000)).use { tensor ->
            session.run(mapOf(AudioVersionWavlmContract.INPUT_NAME to tensor), options).use { result ->
                val output = result.get(AudioVersionWavlmContract.OUTPUT_NAME)
                    .orElseThrow { IllegalStateException("Missing analysis output") } as OnnxTensor
                val values = output.floatBuffer
                require(values.remaining() == AudioVersionWavlmContract.OUTPUT_FRAMES * AudioVersionWavlmContract.OUTPUT_CHANNELS)
                FileOutputStream(destination).use { file ->
                    val buffer = ByteBuffer.allocate(16 * 1024).order(ByteOrder.LITTLE_ENDIAN)
                    while (values.hasRemaining()) {
                        checkCancelled()
                        buffer.clear()
                        while (buffer.remaining() >= 4 && values.hasRemaining()) {
                            val value = values.get()
                            require(value.isFinite())
                            buffer.putFloat(value)
                        }
                        file.write(buffer.array(), 0, buffer.position())
                    }
                }
            }
        }
        checkCancelled()
    }
}
