/// A real measurement taken on a real device.
///
/// Every field is populated from an actual run — initialization is timed,
/// first token is timed, throughput is counted. Nothing here is ever
/// estimated or filled in from a datasheet: a fabricated benchmark in a
/// hackathon submission is worse than no benchmark.
class AiBenchmarkResult {
  const AiBenchmarkResult({
    required this.modelName,
    required this.modelSizeBytes,
    required this.precision,
    required this.runtimeBackend,
    required this.initializationTime,
    required this.timeToFirstToken,
    required this.tokensPerSecond,
    required this.peakMemoryBytes,
    required this.measuredAt,
    this.deviceLabel,
  });

  final String modelName;

  /// On-disk size of the loaded model. -1 when the runtime does not report it.
  final int modelSizeBytes;

  /// e.g. `w4a16`, `fp16`. Reported by the runtime, never assumed.
  final String precision;

  /// e.g. `QNN-HTP (NPU)`, `knowledge-base (no LLM)`.
  final String runtimeBackend;

  final Duration initializationTime;
  final Duration timeToFirstToken;
  final double tokensPerSecond;

  /// Peak RSS during generation. -1 when the platform does not expose it.
  final int peakMemoryBytes;

  final DateTime measuredAt;
  final String? deviceLabel;

  String get modelSizeLabel => modelSizeBytes < 0
      ? 'not reported'
      : '${(modelSizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';

  String get peakMemoryLabel => peakMemoryBytes < 0
      ? 'not reported'
      : '${(peakMemoryBytes / (1024 * 1024)).toStringAsFixed(0)} MB';

  Map<String, dynamic> toJson() => {
    'modelName': modelName,
    'modelSize': modelSizeBytes,
    'precision': precision,
    'runtimeBackend': runtimeBackend,
    'initializationTimeMs': initializationTime.inMilliseconds,
    'timeToFirstTokenMs': timeToFirstToken.inMilliseconds,
    'tokensPerSecond': tokensPerSecond,
    'peakMemory': peakMemoryBytes,
    'measuredAt': measuredAt.toIso8601String(),
    'device': deviceLabel,
  };

  static AiBenchmarkResult? fromNative(Map<Object?, Object?> map) {
    final name = map['modelName'];
    if (name is! String) return null;
    int asInt(Object? value) => value is num ? value.toInt() : -1;
    return AiBenchmarkResult(
      modelName: name,
      modelSizeBytes: asInt(map['modelSize']),
      precision: map['precision'] as String? ?? 'unknown',
      runtimeBackend: map['runtimeBackend'] as String? ?? 'unknown',
      initializationTime: Duration(
        milliseconds: asInt(map['initializationTimeMs']),
      ),
      timeToFirstToken: Duration(
        milliseconds: asInt(map['timeToFirstTokenMs']),
      ),
      tokensPerSecond: (map['tokensPerSecond'] as num?)?.toDouble() ?? 0,
      peakMemoryBytes: asInt(map['peakMemory']),
      measuredAt: DateTime.now(),
      deviceLabel: map['device'] as String?,
    );
  }
}
