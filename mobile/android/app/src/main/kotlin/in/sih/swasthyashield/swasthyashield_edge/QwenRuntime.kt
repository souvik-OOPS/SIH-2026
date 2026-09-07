package `in`.sih.swasthyashield.swasthyashield_edge

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.Keep
import java.io.File
import java.util.concurrent.Executors

@Keep
object NativeLlama {
    val available: Boolean = try { System.loadLibrary("shield_llama"); true } catch (_: UnsatisfiedLinkError) { false }
    external fun load(path: String): Long
    external fun generate(handle: Long, prompt: ByteArray, maximum: Int): ByteArray
    external fun cancel(handle: Long)
    external fun close(handle: Long)
    external fun metrics(handle: Long): DoubleArray
    external fun description(handle: Long): String
}

/** Real local CPU inference. No network call or Qualcomm NPU requirement. */
class QwenRuntime private constructor(private val handle: Long, val modelSizeBytes: Long) {
    var initializationTimeMs = -1L
    val modelName = NativeLlama.description(handle)
    val precision = "GGUF · $modelName"
    val backend = "llama.cpp CPU (2 threads)"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun generate(systemPrompt: String, prompt: String, maxOutputTokens: Int,
        onToken: (String) -> Unit, onDone: (Map<String, Any>) -> Unit, onError: (String) -> Unit) {
        worker.execute {
            try {
                Log.i("ShieldAI", "Local generation started")
                val input = "<|im_start|>system\n$systemPrompt<|im_end|>\n<|im_start|>user\n$prompt\n/no_think<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
                val answer = NativeLlama.generate(handle, input.toByteArray(Charsets.UTF_8), maxOutputTokens).toString(Charsets.UTF_8)
                val metrics = NativeLlama.metrics(handle)
                Log.i("ShieldAI", "Local generation completed: ${metrics[2].toInt()} tokens in ${metrics[1].toLong()} ms")
                main.post {
                    onToken(answer)
                    onDone(mapOf("modelName" to modelName, "modelSize" to modelSizeBytes,
                        "precision" to precision, "runtimeBackend" to backend,
                        "initializationTimeMs" to initializationTimeMs,
                        "timeToFirstTokenMs" to metrics[0].toLong(),
                        "tokensPerSecond" to if (metrics[1] > 0) metrics[2] * 1000 / metrics[1] else 0.0,
                        "peakMemory" to metrics[3].toLong(), "device" to "${Build.MANUFACTURER} ${Build.MODEL}"))
                }
            } catch (error: Throwable) { main.post { onError(error.message ?: "Local generation failed") } }
        }
    }
    fun cancel() = NativeLlama.cancel(handle)
    fun close() { cancel(); worker.execute { NativeLlama.close(handle) }; worker.shutdown() }
    data class Support(val supported: Boolean, val reason: String)
    companion object {
        fun modelFile(context: Context) = File(context.filesDir, "qwen.gguf")
        fun checkSupport(context: Context): Support {
            if (!NativeLlama.available) return Support(false, "Local CPU runtime is not bundled. Build with the prepared llama.cpp source.")
            if (!modelFile(context).isFile) return Support(false, "Import the Qwen GGUF model once in AI diagnostics. The offline guide works immediately.")
            return Support(true, "Local model ready")
        }
        fun create(context: Context): QwenRuntime {
            val file = modelFile(context)
            return QwenRuntime(NativeLlama.load(file.absolutePath), file.length())
        }
    }
}
