import 'package:flutter/services.dart';

class SummaryShareGateway {
  const SummaryShareGateway();
  static const _channel = MethodChannel('in.sih.swasthyashield/sharing');

  /// Opens Android's chooser. Completion says nothing about delivery.
  Future<void> openShareSheet(String text) =>
      _channel.invokeMethod('shareSummary', {'text': text});
}
