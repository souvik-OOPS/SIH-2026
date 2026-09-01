import 'package:flutter/material.dart';

import '../services/model_download_service.dart';

/// Download / installed / error card for the optional offline model.
class ModelDownloadCard extends StatelessWidget {
  const ModelDownloadCard({
    super.key,
    required this.service,
    required this.onDownload,
    required this.onRemove,
  });

  final ModelDownloadService service;
  final VoidCallback onDownload;
  final VoidCallback onRemove;

  static String _sizeLabel(int bytes) =>
      '${(bytes / (1024 * 1024)).round()} MB';

  @override
  Widget build(BuildContext context) {
    final state = service.state;

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
          Row(
            children: [
              const Icon(Icons.download_outlined, color: Color(0xFF9CC9FF)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  switch (state.status) {
                    ModelInstallStatus.installed => 'Offline AI installed',
                    ModelInstallStatus.downloading => 'Downloading model…',
                    ModelInstallStatus.failed => 'Download failed',
                    ModelInstallStatus.notInstalled =>
                      'Enable Offline AI Assistant',
                  },
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (state.status == ModelInstallStatus.notInstalled) ...[
            Text(
              'Download approximately ${_sizeLabel(ModelDownloadService.approximateBytes)} once. '
              'After downloading, the assistant works without internet.',
              style: const TextStyle(color: Color(0xFFC2D7DA), height: 1.35),
            ),
            const SizedBox(height: 8),
            const Row(
              children: [
                Icon(Icons.wifi, size: 15, color: Color(0xFFF6C859)),
                SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Use Wi-Fi — this is a large download.',
                    style: TextStyle(fontSize: 12, color: Color(0xFFF6C859)),
                  ),
                ),
              ],
            ),
            if (!service.isConfigured)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'No model URL is configured in this build, so the download '
                  'cannot start. The assistant still answers from its offline '
                  'guide.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFF7482)),
                ),
              ),
          ],
          if (state.status == ModelInstallStatus.downloading) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: LinearProgressIndicator(
                minHeight: 9,
                value: state.progress <= 0 ? null : state.progress / 100,
                color: const Color(0xFF49D6C7),
                backgroundColor: const Color(0xFF23434D),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${state.progress}%  —  keep this screen open',
              style: const TextStyle(fontSize: 12, color: Color(0xFF91AAB5)),
            ),
          ],
          if (state.status == ModelInstallStatus.failed) ...[
            Text(
              state.error ?? 'The download did not finish.',
              style: const TextStyle(color: Color(0xFFFF7482), height: 1.35),
            ),
          ],
          if (state.status == ModelInstallStatus.installed) ...[
            Text(
              'The assistant answers on this phone with no internet. '
              'Storage used: about ${_sizeLabel(ModelDownloadService.approximateBytes)}.',
              style: const TextStyle(color: Color(0xFFC2D7DA), height: 1.35),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              if (state.status != ModelInstallStatus.installed)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: state.isBusy || !service.isConfigured
                        ? null
                        : onDownload,
                    icon: const Icon(Icons.download),
                    label: Text(
                      state.status == ModelInstallStatus.failed
                          ? 'Try again'
                          : 'Download',
                    ),
                  ),
                ),
              if (state.status == ModelInstallStatus.installed)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove model'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
