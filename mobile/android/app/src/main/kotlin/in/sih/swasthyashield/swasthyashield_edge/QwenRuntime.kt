package `in`.sih.swasthyashield.swasthyashield_edge

import android.content.Context
import android.os.Build

/**
 * The single seam where the Qualcomm on-device LLM runtime gets bound.
 *
 * ## Why this is not implemented yet
 *
 * Binding Qwen3-0.6B requires two things that cannot be satisfied from a
 * development machine alone:
 *
 *  1. The **QAIRT SDK** (v2.29.0+), downloaded from Qualcomm Software Center.
 *     It is account- and license-gated, so it cannot be vendored here.
 *  2. **Snapdragon hardware.** Qualcomm AI Engine Direct is NPU-only; the
 *     published guidance targets Snapdragon 8 Elite class parts (Hexagon v73+)
 *     on Android 15+. There is no emulator path — an x86_64 AVD cannot run it.
 *
 * Rather than ship a stub that pretends to generate text, [checkSupport]
 * reports honestly that the runtime is absent. The Dart layer treats that as
 * "engine unavailable" and falls back to the offline knowledge base, so the
 * assistant keeps working on every device while this remains unbound.
 *
 * ## Implementing it
 *
 * 1. Fetch the Qwen3-0.6B bundle from Qualcomm AI Hub for the exact target
 *    chipset and unpack it as a `genie_bundle` on the device.
 * 2. Add the QAIRT/GenieX runtime libraries to `android/app/src/main/jniLibs`
 *    and the AI Hub Kotlin dependency to `android/app/build.gradle.kts`.
 * 3. Replace [checkSupport] with a real capability probe and [create] with a
 *    real load, then implement [generate] against the streaming callback.
 * 4. Populate the benchmark map from measured values only. Never estimate.
 */
class QwenRuntime private constructor(
    val modelName: String,
    val modelSizeBytes: Long,
    val precision: String,
    val backend: String,
) {

    /**
     * Streams a completion. [onToken] fires per token, [onDone] once with a
     * benchmark map whose values must all be measured, never estimated.
     */
    fun generate(
        systemPrompt: String,
        prompt: String,
        maxOutputTokens: Int,
        onToken: (String) -> Unit,
        onDone: (Map<String, Any?>) -> Unit,
        onError: (String) -> Unit,
    ) {
        onError(
            "The Qualcomm Qwen runtime is not bound in this build. " +
                "See QwenRuntime for the steps.",
        )
    }

    fun close() = Unit

    /** Why the runtime can or cannot run here. */
    data class Support(val supported: Boolean, val reason: String)

    companion object {
        /**
         * Reports whether this device could host the runtime.
         *
         * The OS/ABI checks below are real and worth keeping once the runtime
         * is bound — they are the cheap disqualifiers. The final check is the
         * honest one: the runtime itself is not linked in yet.
         */
        fun checkSupport(context: Context): Support {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                return Support(
                    false,
                    "On-device Qwen needs a newer Android version than this device runs.",
                )
            }
            val isArm = Build.SUPPORTED_ABIS.any { it.startsWith("arm64") }
            if (!isArm) {
                return Support(
                    false,
                    "On-device Qwen needs an arm64 Snapdragon device; this is ${Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"}.",
                )
            }
            if (!Build.SOC_MANUFACTURER.contains("Qualcomm", ignoreCase = true)) {
                return Support(
                    false,
                    "This device does not have a Qualcomm chipset, so the NPU runtime cannot run.",
                )
            }
            return Support(
                false,
                "The Qualcomm QAIRT runtime is not bundled in this build, so Qwen3-0.6B cannot start. " +
                    "The assistant is answering from its offline guide instead.",
            )
        }

        fun create(context: Context, modelId: String): QwenRuntime {
            throw IllegalStateException(
                "The Qualcomm QAIRT runtime is not bundled in this build.",
            )
        }
    }
}
