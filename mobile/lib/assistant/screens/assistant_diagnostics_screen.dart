import 'package:flutter/material.dart';

import '../models/ai_benchmark_result.dart';
// AssistantLanguage's extension getters live here.
import '../models/assistant_context.dart';
import '../services/assistant_service.dart';

/// Engine status and on-device benchmark numbers.
///
/// Shows measurements only after a real run. Where nothing has been measured
/// it says so — a fabricated tokens/sec in a hackathon submission is worse
/// than an empty table, because a judge may believe it.
class AssistantDiagnosticsScreen extends StatelessWidget {
  const AssistantDiagnosticsScreen({super.key, required this.assistant});

  final AssistantService assistant;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: assistant,
      builder: (context, _) {
        final benchmark = assistant.lastBenchmark;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            title: const Text('AI diagnostics'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              _Card(
                title: 'Active engine',
                children: [
                  _Row(label: 'Engine', value: assistant.engineName),
                  _Row(
                    label: 'Language model',
                    value: assistant.usesLlm ? 'Yes' : 'No — offline guide',
                  ),
                  _Row(
                    label: 'Knowledge entries',
                    value: '${assistant.knowledge.entryCount}',
                  ),
                  _Row(
                    label: 'Retrieval',
                    value: 'Ranked local guide · exact-match priority',
                  ),
                  _Row(
                    label: 'Answer language',
                    value: assistant.language.englishName,
                  ),
                ],
              ),
              if (assistant.engineFailureReason != null) ...[
                const SizedBox(height: 16),
                _Card(
                  title: 'Local model setup',
                  children: [
                    Text(
                      assistant.engineFailureReason!,
                      style: const TextStyle(
                        color: Color(0xFFC2D7DA),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'The local CPU runtime works on arm64 Android phones. '
                      'Import the official Qwen3-0.6B GGUF once; subsequent '
                      'answers need no internet. Urgent instructions always '
                      'come directly from the monitoring guide.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF91AAB5),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: assistant.isGenerating
                    ? null
                    : assistant.importLocalModel,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import Qwen GGUF model'),
              ),
              TextButton(
                onPressed: assistant.isGenerating ? null : assistant.initialize,
                child: const Text('Reload local model'),
              ),
              const SizedBox(height: 16),
              if (benchmark == null)
                const _Card(
                  title: 'Benchmark',
                  children: [
                    Text(
                      'No measurement has been taken on this device.\n\n'
                      'These numbers are only ever filled in by a real run on '
                      'real hardware. Nothing here is estimated.',
                      style: TextStyle(color: Color(0xFFC2D7DA), height: 1.4),
                    ),
                  ],
                )
              else
                _BenchmarkCard(result: benchmark),
            ],
          ),
        );
      },
    );
  }
}

class _BenchmarkCard extends StatelessWidget {
  const _BenchmarkCard({required this.result});

  final AiBenchmarkResult result;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Measured on this device',
      children: [
        _Row(label: 'Model', value: result.modelName),
        _Row(label: 'Model size', value: result.modelSizeLabel),
        _Row(label: 'Precision', value: result.precision),
        _Row(label: 'Backend', value: result.runtimeBackend),
        _Row(
          label: 'Init time',
          value: result.initializationTime.isNegative
              ? 'Not measured'
              : '${result.initializationTime.inMilliseconds} ms',
        ),
        _Row(
          label: 'Time to first token',
          value: result.timeToFirstToken.isNegative
              ? 'Not measured'
              : '${result.timeToFirstToken.inMilliseconds} ms',
        ),
        _Row(
          label: 'Throughput incl. prompt',
          value: '${result.tokensPerSecond.toStringAsFixed(1)} tok/s',
        ),
        _Row(label: 'App peak memory', value: result.peakMemoryLabel),
        if (result.deviceLabel != null)
          _Row(label: 'Device', value: result.deviceLabel!),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF102833),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: Color(0xFF91AAB5),
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFFB8CED5)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
