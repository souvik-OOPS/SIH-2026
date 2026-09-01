import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart';

import '../models/assistant_mode.dart';

/// Outcome of probing the device, with the reason kept for the UI.
class EngineSelection {
  const EngineSelection({
    required this.mode,
    required this.reason,
    this.builtInAvailability,
    this.canDownloadModel = false,
  });

  final AssistantMode mode;

  /// Plain-language explanation, shown on the setup screen.
  final String reason;
  final BuiltInAiAvailability? builtInAvailability;

  /// True when offering a ~300 MB download is a sensible next step.
  final bool canDownloadModel;
}

/// Decides which engine answers, in the documented priority order:
/// built-in AI, then a downloaded Gemma 3 270M, then knowledge-only.
///
/// Probing is isolated here so [AssistantService] holds policy, not platform
/// detail, and so the decision can be unit-tested with injected probes.
class AiEngineSelector {
  AiEngineSelector({
    Future<BuiltInAiAvailability> Function()? probeBuiltIn,
    Future<bool> Function()? probeDownloadedModel,
  }) : _probeBuiltIn = probeBuiltIn ?? BuiltInAi.availability,
       _probeDownloadedModel = probeDownloadedModel ?? _defaultModelProbe;

  final Future<BuiltInAiAvailability> Function() _probeBuiltIn;
  final Future<bool> Function() _probeDownloadedModel;

  /// A model is installed when core has an active inference spec that is not
  /// the inert built-in placeholder.
  static Future<bool> _defaultModelProbe() async {
    try {
      final spec = FlutterGemma.activeModelSpec;
      return spec != null && spec.fileType != ModelFileType.builtIn;
    } on Object {
      return false;
    }
  }

  Future<EngineSelection> select() async {
    final availability = await _safeProbeBuiltIn();

    if (availability == BuiltInAiAvailability.available) {
      return EngineSelection(
        mode: AssistantMode.builtIn,
        reason: 'Using the AI built into this device. No download needed.',
        builtInAvailability: availability,
      );
    }

    if (await _safeProbeModel()) {
      return EngineSelection(
        mode: AssistantMode.downloadedModel,
        reason: 'Using the offline model installed on this phone.',
        builtInAvailability: availability,
      );
    }

    // Downloadable/downloading are built-in states the OS may still resolve,
    // but we do not block on them - the offline model is the reliable path.
    return EngineSelection(
      mode: AssistantMode.localKnowledgeOnly,
      reason: _reasonFor(availability),
      builtInAvailability: availability,
      canDownloadModel: true,
    );
  }

  Future<BuiltInAiAvailability> _safeProbeBuiltIn() async {
    try {
      return await _probeBuiltIn();
    } on Object catch (error) {
      debugPrint('[assistant] built-in AI probe failed: $error');
      return BuiltInAiAvailability.unavailableOther;
    }
  }

  Future<bool> _safeProbeModel() async {
    try {
      return await _probeDownloadedModel();
    } on Object catch (error) {
      debugPrint('[assistant] downloaded-model probe failed: $error');
      return false;
    }
  }

  static String _reasonFor(BuiltInAiAvailability availability) =>
      switch (availability) {
        BuiltInAiAvailability.available => 'Built-in AI is available.',
        BuiltInAiAvailability.downloadable =>
          'This device can enable built-in AI, but it is not ready yet. '
              'You can download the offline model instead.',
        BuiltInAiAvailability.downloading =>
          'The device is still preparing its built-in AI.',
        BuiltInAiAvailability.unavailableDeviceUnsupported =>
          'This device does not support built-in AI.',
        BuiltInAiAvailability.unavailableOsTooOld =>
          'This Android version is too old for built-in AI.',
        BuiltInAiAvailability.unavailableDisabled =>
          'Built-in AI is switched off on this device.',
        BuiltInAiAvailability.unavailableOther =>
          'Built-in AI is not available on this device.',
      };
}
