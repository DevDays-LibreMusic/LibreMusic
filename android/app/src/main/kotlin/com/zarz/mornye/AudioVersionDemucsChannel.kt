package com.zarz.mornye

import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** No audio/model download: this channel accepts an explicitly selected local model only. */
internal class AudioVersionDemucsChannel(context: Context, messenger: BinaryMessenger) : AutoCloseable {
    private val context = context.applicationContext
    private val channel = MethodChannel(messenger, "com.zarz.mornye/audio_version_demucs")
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "audio-version-demucs").apply { isDaemon = true }
    }
    private val modelStore = AudioVersionModelStore(File(context.filesDir, "audio-version-models"), AudioVersionDemucsContract.MODEL_BYTES, AudioVersionDemucsContract.MODEL_SHA256, AudioVersionDemucsContract.MODEL_FILENAME)
    private val outputs = File(context.cacheDir, "audio-version-demucs")
    private val requests = ConcurrentHashMap<String, Request>()
    private val closed = AtomicBoolean(false)

    init { channel.setMethodCallHandler(::handle) }

    private class Request {
        private val cancelled = AtomicBoolean(false)
        private var active: OrtSession.RunOptions? = null
        fun check() {
            if (cancelled.get() || Thread.currentThread().isInterrupted) throw CancellationException()
        }
        @Synchronized fun bind(options: OrtSession.RunOptions?) {
            active = options
            if (options != null && cancelled.get()) options.setTerminate(true)
        }
        @Synchronized fun cancel() {
            cancelled.set(true)
            try { active?.setTerminate(true) } catch (_: Exception) { }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val suppliedId = (call.arguments as? Map<*, *>)?.get("request_id") as? String
        if (call.method == "cancel") {
            suppliedId?.let { requests[it]?.cancel() }
            result.success(null)
            return
        }
        if (call.method !in setOf("status", "prepareModel", "importModel", "infer", "releaseOutputs")) {
            result.notImplemented()
            return
        }
        if (closed.get()) {
            result.error("unavailable", "Local analysis is unavailable", null)
            return
        }
        if (requests.size >= 8) {
            result.error("unavailable", "Local analysis is busy", null)
            return
        }
        val id = suppliedId ?: UUID.randomUUID().toString()
        if (id.length !in 1..160) {
            result.error("invalid_request", "Invalid analysis request", null)
            return
        }
        val request = Request()
        if (requests.putIfAbsent(id, request) != null) {
            result.error("invalid_request", "Analysis request already exists", null)
            return
        }
        executor.execute {
            var pendingOutput: File? = null
            var delivered = false
            try {
                request.check()
                val answer = when (call.method) {
                    "status" -> modelStatus(request)
                    "prepareModel" -> {
                        modelStore.ensureBundled({ context.assets.open("audio-version-models/htdemucs-trunk-fp32.onnx") }, request::check)
                        contract("available")
                    }
                    "importModel" -> {
                        val source = requireNotNull(call.argument<String>("source"))
                        openSelectedModel(source).use { modelStore.import(it, request::check) }
                        contract("available")
                    }
                    "infer" -> infer(call, request)
                    "releaseOutputs" -> {
                        val outputId = requireNotNull(call.argument<String>("output_id"))
                        require(UUID.fromString(outputId).toString() == outputId)
                        privateOutput(outputId).deleteRecursively()
                        null
                    }
                    else -> error("Unreachable")
                }
                pendingOutput = (answer as? Map<*, *>)?.get("output_id")?.let {
                    privateOutput(it as String)
                }
                request.check()
                main.post { result.success(answer) }
                delivered = true
            } catch (_: CancellationException) {
                main.post { result.error("cancelled", "Analysis cancelled", null) }
            } catch (_: AudioVersionInvalidModel) {
                main.post { result.error("invalid_model", "Unsupported or damaged analysis model", null) }
            } catch (_: OutOfMemoryError) {
                main.post { result.error("unavailable", "Insufficient memory for local analysis", null) }
            } catch (_: Exception) {
                // Paths, provider URIs and audio contents never become diagnostic payloads.
                val cancelled = try { request.check(); false } catch (_: CancellationException) { true }
                main.post {
                    result.error(
                        if (cancelled) "cancelled" else "unavailable",
                        if (cancelled) "Analysis cancelled" else "Local analysis is unavailable",
                        null,
                    )
                }
            } finally {
                if (!delivered) pendingOutput?.deleteRecursively()
                requests.remove(id, request)
            }
        }
    }

    private fun modelStatus(request: Request): Map<String, Any> =
        contract(if (modelStore.verifiedModel(request::check) != null) "available" else "unavailable")

    private fun contract(status: String): Map<String, Any> = mapOf(
        "status" to status,
        "version" to AudioVersionDemucsContract.MODEL_ID,
        "model_sha256" to AudioVersionDemucsContract.MODEL_SHA256,
    )

    private fun openSelectedModel(source: String): InputStream {
        val uri = Uri.parse(source)
        return when (uri.scheme) {
            "content" -> requireNotNull(context.contentResolver.openInputStream(uri))
            "file" -> File(requireNotNull(uri.path)).inputStream()
            null, "" -> File(source).inputStream()
            else -> throw IllegalArgumentException("Model must be selected locally")
        }
    }

    private fun privateInput(path: String): File = File(path).canonicalFile.also { file ->
        require(file.isFile && listOf(context.cacheDir, context.filesDir).any {
            file.path.startsWith(it.canonicalPath + File.separator)
        }) { "Analysis input must be app-owned" }
    }

    private fun privateOutput(id: String): File = File(outputs, id).canonicalFile.also {
        require(it.parentFile == outputs.canonicalFile)
    }

    private fun infer(call: MethodCall, request: Request): Map<String, Any> {
        val clips = requireNotNull(call.argument<List<Map<String, Any>>>("clips"))
        require(clips.size in 1..6)
        val ids = clips.map { requireNotNull(it["clip_id"] as? String).also { id -> require(id.length in 1..160) } }
        require(ids.toSet().size == ids.size)
        val inputs = clips.map { clip ->
            privateInput(requireNotNull(clip["wave_path"] as? String)).also { require(it.length() == 2L * 343980 * 4) } to
                privateInput(requireNotNull(clip["spec_path"] as? String)).also { require(it.length() == 4L * 2048 * 336 * 4) }
        }
        val model = modelStore.verifiedModel(request::check) ?: return contract("unavailable")
        check(outputs.isDirectory || outputs.mkdirs())
        val outputId = UUID.randomUUID().toString()
        val work = privateOutput(outputId)
        check(work.mkdir())
        var published = false
        try {
            val environment = OrtEnvironment.getEnvironment()
            val contexts = mutableListOf<Map<String, String>>()
            AudioVersionWavlmRuntime.sessionOptions().use { options ->
                environment.createSession(model.path, options).use { session ->
                    AudioVersionDemucsRuntime.checkShape(session)
                    OrtSession.RunOptions().use { run ->
                        request.bind(run)
                        try {
                            for ((index, pair) in inputs.withIndex()) {
                                val freq = File(work, "$index-freq.f32le")
                                val time = File(work, "$index-time.f32le")
                                AudioVersionDemucsRuntime.runChunk(environment, session, run, pair.first, pair.second, freq, time, request::check)
                                contexts += mapOf("clip_id" to ids[index], "freq_path" to freq.path, "time_path" to time.path)
                            }
                        } finally { request.bind(null) }
                    }
                }
            }
            request.check()
            published = true
            return contract("verified") + mapOf("output_id" to outputId, "contexts" to contexts)
        } finally { if (!published) work.deleteRecursively() }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        channel.setMethodCallHandler(null)
        requests.values.forEach { it.cancel() }
        // Drain queued requests so their Dart futures receive cancellation, not an orphaned reply.
        executor.shutdown()
    }
}
