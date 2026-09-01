import 'package:flutter/material.dart';

import '../models/assistant_mode.dart';
import '../services/assistant_service.dart';
import '../widgets/assistant_status_badge.dart';
import '../widgets/model_download_card.dart';

/// Optional setup for the downloadable offline model.
///
/// Reachable but never blocking: the assistant already answers from its
/// bundled guide, so a user who declines the download loses quality, not the
/// feature.
class OfflineAiSetupScreen extends StatelessWidget {
  const OfflineAiSetupScreen({super.key, required this.assistant});

  final AssistantService assistant;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([assistant, assistant.downloads]),
      builder: (context, _) {
        final selection = assistant.selection;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            title: const Text('Offline AI Assistant'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              AssistantStatusBadge(mode: assistant.mode),
              const SizedBox(height: 18),
              if (selection != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF102833),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.07),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, color: Color(0xFF9CC9FF)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          selection.reason,
                          style: const TextStyle(
                            color: Color(0xFFC2D7DA),
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              if (assistant.mode == AssistantMode.builtIn)
                const _BuiltInNotice()
              else
                ModelDownloadCard(
                  service: assistant.downloads,
                  onDownload: () =>
                      assistant.downloadOfflineModel(onProgress: (_) {}),
                  onRemove: () async {
                    await assistant.downloads.remove();
                    await assistant.initialize();
                  },
                ),
              const SizedBox(height: 20),
              const Text(
                'What the assistant can and cannot do',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'It explains readings, warnings and device status in plain '
                'language. It does not decide whether an emergency exists and '
                'cannot change any alert — those come from the app itself. It '
                'does not diagnose illness.',
                style: TextStyle(color: Color(0xFFC2D7DA), height: 1.4),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BuiltInNotice extends StatelessWidget {
  const _BuiltInNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF102833),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: const Row(
        children: [
          Icon(Icons.verified_outlined, color: Color(0xFF49D6C7)),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'This device has built-in AI, so nothing needs downloading.',
              style: TextStyle(color: Color(0xFFC2D7DA), height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
