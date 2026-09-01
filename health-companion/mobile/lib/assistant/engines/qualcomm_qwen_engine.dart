import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/ai_benchmark_result.dart';
// AssistantLanguage's `code` extension lives here; extensions are only in
// scope when their defining library is imported directly.
import '../models/assistant_context.dart';
import '../models/assistant_request.dart';
import 'assistant_engine.dart';

/// Qwen3-0.6B on the Qualcomm on-device stack, reached over platform channels.
///
/// All Qualcomm-specific code lives on the Kotlin side; this class knows only
/// the channel contract, so nothing QNN-shaped leaks into the Flutter app.
///
/// **Hardware requirements are strict.** The Qualcomm AI Engine Direct backend
/// is NPU-only and the published Genie/GenieX guidance targets Snapdragon
/// 8 Elite class parts (Hexagon v73+) on Android 15+, with the QAIRT runtime
/// present on device. On anything else [initialize] throws
/// [AssistantEngineUnavailable] and the service falls through to the next
/// engine — which is the normal, expected path on most phones.
///
/// **Not verified on hardware.** No Snapdragon Elite device was available, so
/// this path is written against the documented channel contract and compiles,
/// but has never executed a real inference. Treat every timing as unmeasured
/// until [lastBenchmark] is populated by an actual run.
class QualcommQwenEngine implements AssistantEngine {
  QualcommQwenEngine({
    MethodChannel? methodChannel,
    EventChannel? tokenChannel,
    this.modelId = _configuredModelId,
  }) : _methods = methodChannel ?? const MethodChannel(_methodChannelName),
       _tokens = tokenChannel ?? const EventChannel(_tokenChannelName);

  static const _methodChannelName = 'in.sih.swasthyashield/qwen';
  static const _tokenChannelName = 'in.sih.swasthyashield/qwen_tokens';

  /// Which AI Hub bundle to load. Configure at build time with
  /// `--dart-define=QWEN_MODEL_ID=...`; never hard-code a token or key.
  static const _configuredModelId = String.fromEnvironment(
    'QWEN_MODEL_ID',
    defaultValue: 'qwen3-0.6b',
  );

  final MethodChannel _methods;
  final EventChannel _tokens;
  final String modelId;

  bool _ready = false;
  AiBenchmarkResult? _benchmark;

  @override
  String get displayName => 'Qwen3-0.6B (Qualcomm NPU)';

  @override
  bool get isReady => _ready;

  @override
  AiBenchmarkResult? get lastBenchmark => _benchmark;

  @override
  Future<void> initialize() async {
    try {
      final result = await _methods.invokeMapMethod<String, Object?>(
        'initialize',
        {'modelId': modelId},
      );
      if (result == null || result['ready'] != true) {
        throw AssistantEngineUnavailable(
          result?['reason'] as String? ??
              'The Qualcomm runtime did not report ready.',
          code: 'not_ready',
        );
      }
      _benchmark = AiBenchmarkResult.fromNative(result);
      _ready = true;
    } on MissingPluginException {
      throw const AssistantEngineUnavailable(
        'The Qualcomm assistant runtime is not built into this app.',
        code: 'missing_plugin',
      );
    } on PlatformException catch (error) {
      throw AssistantEngineUnavailable(
        error.message ?? 'This device cannot run the Qualcomm assistant.',
        code: error.code,
      );
    }
  }

  @override
  Stream<String> generate(AssistantRequest request) async* {
    if (!_ready) {
      throw const AssistantGenerationException(
        'The engine was not initialized.',
        code: 'not_initialized',
      );
    }

    // Subscribe before starting so no early token is missed.
    final stream = _tokens.receiveBroadcastStream().cast<Object?>();
    final queue = StreamController<String>();
    late final StreamSubscription<Object?> subscription;

    subscription = stream.listen(
      (event) {
        if (event is String) {
          queue.add(event);
          return;
        }
        if (event is Map) {
          final token = event['token'];
          if (token is String && token.isNotEmpty) queue.add(token);
          if (event['done'] == true) unawaited(queue.close());
          final benchmark = event['benchmark'];
          if (benchmark is Map) {
            _benchmark = AiBenchmarkResult.fromNative(benchmark) ?? _benchmark;
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        queue.addError(
          AssistantGenerationException(
            error is PlatformException
                ? error.message ?? 'Generation failed.'
                : '$error',
            code: error is PlatformException ? error.code : null,
          ),
          stackTrace,
        );
        unawaited(queue.close());
      },
      onDone: () => unawaited(queue.close()),
    );

    try {
      await _methods.invokeMethod<void>('generate', {
        'systemPrompt': request.systemPrompt,
        'prompt': request.toPrompt(),
        'maxOutputTokens': request.maxOutputTokens,
        'language': request.language.code,
      });
      yield* queue.stream;
    } on PlatformException catch (error) {
      throw AssistantGenerationException(
        error.message ?? 'Generation failed.',
        code: error.code,
      );
    } finally {
      await subscription.cancel();
      if (!queue.isClosed) await queue.close();
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
    try {
      await _methods.invokeMethod<void>('dispose');
    } on Object catch (error) {
      debugPrint('[assistant] qwen dispose failed: $error');
    }
  }
}
