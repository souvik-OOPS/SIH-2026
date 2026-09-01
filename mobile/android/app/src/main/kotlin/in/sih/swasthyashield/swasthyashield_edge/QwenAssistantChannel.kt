package `in`.sih.swasthyashield.swasthyashield_edge

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between Flutter and the Qualcomm on-device LLM runtime.
 *
 * Everything Qualcomm-specific is confined to this file and to
 * [QwenRuntime]. The Flutter side knows only the channel contract, so the
 * rest of the app has no dependency on QNN/QAIRT at all.
 *
 * ## Contract
 *
 * Method channel `in.sih.swasthyashield/qwen`:
 *  - `initialize({modelId: String})` -> Map with at minimum `ready: Boolean`.
 *    When not ready it carries `reason: String`. When ready it may also carry
 *    the benchmark fields consumed by `AiBenchmarkResult.fromNative`.
 *  - `generate({systemPrompt, prompt, maxOutputTokens, language})` -> null.
 *    Tokens arrive on the event channel.
 *  - `dispose()` -> null.
 *
 * Event channel `in.sih.swasthyashield/qwen_tokens` emits maps:
 *  - `{token: String}` per token
 *  - `{done: true, benchmark: {...}}` at the end of a turn
 *
 * ## Status
 *
 * [QwenRuntime] is the seam where the QAIRT/GenieX runtime is bound. It is
 * deliberately NOT implemented here: doing so requires the QAIRT SDK, which
 * is license-gated, and a Snapdragon device to verify against. Until that
 * lands, [isSupported] returns false with a readable reason, the Dart layer
 * treats that as "engine unavailable", and the assistant falls back to its
 * offline knowledge base. That is a working, honest state — not a stub
 * pretending to be a model.
 */
class QwenAssistantChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private var events: EventChannel.EventSink? = null
    private var runtime: QwenRuntime? = null

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    fun dispose() {
        runtime?.close()
        runtime = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "initialize" -> initialize(call.argument<String>("modelId"), result)
            "generate" -> generate(call, result)
            "dispose" -> {
                runtime?.close()
                runtime = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initialize(modelId: String?, result: MethodChannel.Result) {
        val support = QwenRuntime.checkSupport(context)
        if (!support.supported) {
            // Not an error: most devices land here, and the Dart side treats
            // it as "try the next engine".
            result.success(mapOf("ready" to false, "reason" to support.reason))
            return
        }
        try {
            val started = System.nanoTime()
            val created = QwenRuntime.create(context, modelId ?: DEFAULT_MODEL_ID)
            runtime = created
            val initMs = (System.nanoTime() - started) / 1_000_000
            result.success(
                mapOf(
                    "ready" to true,
                    "modelName" to created.modelName,
                    "modelSize" to created.modelSizeBytes,
                    "precision" to created.precision,
                    "runtimeBackend" to created.backend,
                    "initializationTimeMs" to initMs,
                    "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
                ),
            )
        } catch (error: Throwable) {
            result.success(
                mapOf(
                    "ready" to false,
                    "reason" to (error.message ?: "The Qualcomm runtime failed to start."),
                ),
            )
        }
    }

    private fun generate(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val active = runtime
        if (active == null) {
            result.error("not_initialized", "The runtime is not initialized.", null)
            return
        }
        val sink = events
        if (sink == null) {
            result.error("no_listener", "No token listener is attached.", null)
            return
        }

        try {
            active.generate(
                systemPrompt = call.argument<String>("systemPrompt").orEmpty(),
                prompt = call.argument<String>("prompt").orEmpty(),
                maxOutputTokens = call.argument<Int>("maxOutputTokens") ?: 220,
                onToken = { token -> sink.success(mapOf("token" to token)) },
                onDone = { benchmark ->
                    sink.success(mapOf("done" to true, "benchmark" to benchmark))
                },
                onError = { message ->
                    sink.error("generation_failed", message, null)
                },
            )
            result.success(null)
        } catch (error: Throwable) {
            result.error(
                "generation_failed",
                error.message ?: "Generation failed.",
                null,
            )
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private companion object {
        const val METHOD_CHANNEL = "in.sih.swasthyashield/qwen"
        const val EVENT_CHANNEL = "in.sih.swasthyashield/qwen_tokens"
        const val DEFAULT_MODEL_ID = "qwen3-0.6b"
    }
}
