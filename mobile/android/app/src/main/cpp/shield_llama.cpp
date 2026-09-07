#include <jni.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <string>
#include <vector>
#include <sys/resource.h>
#include "llama.h"

struct Runtime { llama_model * model; std::atomic<bool> cancelled{false}; double firstMs = -1, elapsedMs = 0, tokens = 0, peakBytes = -1; };
static void fail(JNIEnv * env, const char * message) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message);
}
extern "C" JNIEXPORT jlong JNICALL
Java_in_sih_swasthyashield_swasthyashield_1edge_NativeLlama_load(JNIEnv * env, jobject, jstring path) {
    llama_backend_init();
    const char * file = env->GetStringUTFChars(path, nullptr);
    auto params = llama_model_default_params(); params.n_gpu_layers = 0;
    auto model = llama_model_load_from_file(file, params);
    env->ReleaseStringUTFChars(path, file);
    if (!model) { fail(env, "Could not load the local GGUF model."); return 0; }
    return reinterpret_cast<jlong>(new Runtime{model});
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_in_sih_swasthyashield_swasthyashield_1edge_NativeLlama_generate(JNIEnv * env, jobject, jlong handle, jbyteArray input, jint maximum) {
    auto runtime = reinterpret_cast<Runtime *>(handle);
    runtime->cancelled = false;
    runtime->firstMs = -1;
    auto cp = llama_context_default_params();
    cp.n_ctx = 2048; cp.n_batch = 128; cp.n_ubatch = 128; cp.n_threads = 2; cp.n_threads_batch = 2;
    cp.abort_callback = [](void * data) { return static_cast<Runtime *>(data)->cancelled.load(); };
    cp.abort_callback_data = runtime;
    auto ctx = llama_init_from_model(runtime->model, cp);
    if (!ctx) { fail(env, "Not enough memory for local chat."); return nullptr; }
    const auto vocab = llama_model_get_vocab(runtime->model);
    const int size = env->GetArrayLength(input);
    std::string prompt(size, '\0');
    env->GetByteArrayRegion(input, 0, size, reinterpret_cast<jbyte *>(prompt.data()));
    int count = -llama_tokenize(vocab, prompt.data(), size, nullptr, 0, true, true);
    const int limit = std::clamp(static_cast<int>(maximum), 1, 160);
    if (count <= 0 || count + limit > 2048) {
        llama_free(ctx); fail(env, "Conversation is too long. Clear chat and try a shorter question."); return nullptr;
    }
    std::vector<llama_token> tokens(count);
    llama_tokenize(vocab, prompt.data(), size, tokens.data(), count, true, true);
    auto sampler = llama_sampler_init_greedy();
    const auto started = std::chrono::steady_clock::now();
    std::string text;
    int decoded = 0;
    bool okay = true;
    for (int offset = 0; offset < count && okay; offset += 128) {
        okay = llama_decode(ctx, llama_batch_get_one(tokens.data() + offset, std::min(128, count - offset))) == 0;
    }
    for (int i = 0; i < limit && okay && !runtime->cancelled; ++i) {
        if (std::chrono::steady_clock::now() - started > std::chrono::seconds(45)) break;
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        if (i == 0) runtime->firstMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
        std::vector<char> piece(256);
        int n = llama_token_to_piece(vocab, token, piece.data(), piece.size(), 0, true);
        if (n < 0) {
            piece.resize(-n);
            n = llama_token_to_piece(vocab, token, piece.data(), piece.size(), 0, true);
        }
        if (n > 0) text.append(piece.data(), n);
        decoded++;
        okay = llama_decode(ctx, llama_batch_get_one(&token, 1)) == 0;
    }
    llama_sampler_free(sampler);
    runtime->elapsedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    runtime->tokens = decoded;
    struct rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) == 0) runtime->peakBytes = usage.ru_maxrss * 1024.0;
    llama_free(ctx);
    if (!okay || runtime->cancelled) { fail(env, "Local generation stopped. The offline guide remains available."); return nullptr; }
    // Return UTF-8 bytes: JNI modified UTF-8 strings corrupt some languages.
    jbyteArray output = env->NewByteArray(text.size());
    env->SetByteArrayRegion(output, 0, text.size(), reinterpret_cast<const jbyte *>(text.data()));
    return output;
}
extern "C" JNIEXPORT void JNICALL
Java_in_sih_swasthyashield_swasthyashield_1edge_NativeLlama_cancel(JNIEnv *, jobject, jlong handle) {
    if (handle) reinterpret_cast<Runtime *>(handle)->cancelled = true;
}
extern "C" JNIEXPORT jdoubleArray JNICALL
Java_in_sih_swasthyashield_swasthyashield_1edge_NativeLlama_metrics(JNIEnv * env, jobject, jlong handle) {
    auto runtime = reinterpret_cast<Runtime *>(handle);
    const double data[] = {runtime->firstMs, runtime->elapsedMs, runtime->tokens, runtime->peakBytes};
    auto result = env->NewDoubleArray(4); env->SetDoubleArrayRegion(result, 0, 4, data); return result;
}
extern "C" JNIEXPORT jstring JNICALL
Java_in_sih_swasthyashield_swasthyashield_1edge_NativeLlama_description(JNIEnv * env, jobject, jlong handle) {
    char text[256]; llama_model_desc(reinterpret_cast<Runtime *>(handle)->model, text, sizeof(text));
    return env->NewStringUTF(text);
}
extern "C" JNIEXPORT void JNICALL
Java_in_sih_swasthyashield_swasthyashield_1edge_NativeLlama_close(JNIEnv *, jobject, jlong handle) {
    auto runtime = reinterpret_cast<Runtime *>(handle);
    if (runtime) { llama_model_free(runtime->model); delete runtime; }
}
