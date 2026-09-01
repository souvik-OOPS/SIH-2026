import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

enum ModelInstallStatus { notInstalled, downloading, installed, failed }

class ModelInstallState {
  const ModelInstallState({
    required this.status,
    this.progress = 0,
    this.error,
  });

  final ModelInstallStatus status;

  /// 0-100.
  final int progress;
  final String? error;

  bool get isBusy => status == ModelInstallStatus.downloading;
}

/// Downloads and manages the optional Gemma 3 270M `.litertlm`.
///
/// The model is never packaged in the APK: it is fetched once, on request,
/// from a configurable URL. Nothing here holds a secret — the URL and any
/// token come from `--dart-define` at build time so they stay out of source
/// control. For production this whole class is the seam to swap for Google
/// Play On-device AI / AI Packs delivery.
class ModelDownloadService extends ChangeNotifier {
  ModelDownloadService({String? modelUrl, String? accessToken, String? modelId})
    : modelUrl = modelUrl ?? _configuredUrl,
      _accessToken = accessToken ?? _configuredToken,
      modelId = modelId ?? _configuredId;

  /// Configure with:
  ///   --dart-define=ASSISTANT_MODEL_URL=https://.../gemma3-270m-it.litertlm
  static const _configuredUrl = String.fromEnvironment(
    'ASSISTANT_MODEL_URL',
    defaultValue: '',
  );

  /// Optional bearer/HF token. Never commit a real value.
  static const _configuredToken = String.fromEnvironment(
    'ASSISTANT_MODEL_TOKEN',
    defaultValue: '',
  );

  static const _configuredId = String.fromEnvironment(
    'ASSISTANT_MODEL_ID',
    defaultValue: 'gemma3-270m-it',
  );

  final String modelUrl;
  final String _accessToken;
  final String modelId;

  /// Approximate on-disk size, shown before the user commits to the download.
  static const approximateBytes = 300 * 1024 * 1024;

  ModelInstallState _state = const ModelInstallState(
    status: ModelInstallStatus.notInstalled,
  );
  ModelInstallState get state => _state;

  bool get isConfigured => modelUrl.isNotEmpty;

  /// Reflects core's active spec, so an install from a previous run is seen.
  Future<void> refreshInstalledState() async {
    if (_state.isBusy) return;
    try {
      final spec = FlutterGemma.activeModelSpec;
      final installed = spec != null && spec.fileType != ModelFileType.builtIn;
      _set(
        ModelInstallState(
          status: installed
              ? ModelInstallStatus.installed
              : ModelInstallStatus.notInstalled,
        ),
      );
    } on Object {
      _set(const ModelInstallState(status: ModelInstallStatus.notInstalled));
    }
  }

  /// Downloads and installs the model. Returns true on success.
  ///
  /// Never throws to the caller: every failure becomes a [ModelInstallState]
  /// carrying a readable reason, because the assistant is optional and must
  /// not be able to take the app down with it.
  Future<bool> download({void Function(int progress)? onProgress}) async {
    if (_state.isBusy) return false;
    if (!isConfigured) {
      _set(
        const ModelInstallState(
          status: ModelInstallStatus.failed,
          error:
              'No model URL is configured. Build with '
              '--dart-define=ASSISTANT_MODEL_URL=<url>.',
        ),
      );
      return false;
    }

    _set(const ModelInstallState(status: ModelInstallStatus.downloading));
    try {
      var builder =
          FlutterGemma.installModel(
            modelType: ModelType.gemmaIt,
            fileType: ModelFileType.litertlm,
          ).fromNetwork(
            modelUrl,
            token: _accessToken.isEmpty ? null : _accessToken,
          );

      builder = builder.withProgress((progress) {
        _set(
          ModelInstallState(
            status: ModelInstallStatus.downloading,
            progress: progress.clamp(0, 100),
          ),
        );
        onProgress?.call(progress);
      });

      await builder.install();
      _set(
        const ModelInstallState(
          status: ModelInstallStatus.installed,
          progress: 100,
        ),
      );
      return true;
    } on Object catch (error) {
      debugPrint('[assistant] model download failed: $error');
      _set(
        ModelInstallState(
          status: ModelInstallStatus.failed,
          error: _readableError(error),
        ),
      );
      return false;
    }
  }

  Future<void> remove() async {
    try {
      await FlutterGemma.uninstallModel(modelId);
    } on Object catch (error) {
      debugPrint('[assistant] model removal failed: $error');
    }
    _set(const ModelInstallState(status: ModelInstallStatus.notInstalled));
  }

  static String _readableError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('space') || text.contains('enospc')) {
      return 'Not enough free storage for the model. Free up about 300 MB '
          'and try again.';
    }
    if (text.contains('socket') ||
        text.contains('network') ||
        text.contains('timeout') ||
        text.contains('connection')) {
      return 'The download could not reach the server. Check your connection '
          'and try again.';
    }
    if (text.contains('401') || text.contains('403')) {
      return 'The model URL rejected the request. Check the configured '
          'access token.';
    }
    if (text.contains('404')) {
      return 'The model was not found at the configured URL.';
    }
    return 'The download failed: $error';
  }

  void _set(ModelInstallState state) {
    _state = state;
    notifyListeners();
  }
}
