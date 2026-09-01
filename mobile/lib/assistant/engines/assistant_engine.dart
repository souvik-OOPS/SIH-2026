import '../models/ai_benchmark_result.dart';
import '../models/assistant_request.dart';

/// How an engine produces text. Implementations must never reach into
/// application state — they receive a finished [AssistantRequest] and emit
/// display text, nothing else.
abstract interface class AssistantEngine {
  /// Human-readable name for the status badge, e.g. `Qwen3-0.6B (NPU)`.
  String get displayName;

  /// True once [initialize] has succeeded and [generate] can be called.
  bool get isReady;

  /// The last real measurement, or null if nothing has been measured yet.
  AiBenchmarkResult? get lastBenchmark;

  /// Prepares the engine. Throws [AssistantEngineUnavailable] when this
  /// device cannot run it — callers treat that as "try the next engine",
  /// never as a crash.
  Future<void> initialize();

  /// Streams the answer token by token so the UI can render as it arrives.
  Stream<String> generate(AssistantRequest request);

  Future<void> dispose();
}

/// Thrown by [AssistantEngine.initialize] when the engine cannot run here.
///
/// Carries a plain-language [reason] because it is shown to the user on the
/// setup screen — "unsupported device" needs to say *why*.
class AssistantEngineUnavailable implements Exception {
  const AssistantEngineUnavailable(this.reason, {this.code});

  final String reason;
  final String? code;

  @override
  String toString() => 'AssistantEngineUnavailable($code): $reason';
}

/// Thrown when generation itself fails after a successful initialize.
class AssistantGenerationException implements Exception {
  const AssistantGenerationException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'AssistantGenerationException($code): $message';
}
