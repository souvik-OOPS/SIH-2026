import 'dart:convert';

import '../core/models/telemetry_frame.dart';

/// Reassembles the explicit default-MTU-safe fragments specified in
/// docs/ble_protocol.md. Invalid or missing fragments discard only that frame.
class BlePacketAssembler {
  static final _fragmentPattern = RegExp(r'^@(\d+),(\d+)/(\d+):(.*)$');

  _PendingPacket? _pending;

  TelemetryFrame? accept(List<int> bytes) {
    try {
      final text = utf8.decode(bytes, allowMalformed: false);
      if (text.startsWith('{')) return _parseDocument(text);

      final match = _fragmentPattern.firstMatch(text);
      if (match == null) {
        reset();
        return null;
      }

      final sequence = int.tryParse(match.group(1)!);
      final part = int.tryParse(match.group(2)!);
      final total = int.tryParse(match.group(3)!);
      final payload = match.group(4)!;
      if (sequence == null ||
          part == null ||
          total == null ||
          part < 1 ||
          total < part) {
        reset();
        return null;
      }

      if (_pending == null ||
          _pending!.sequence != sequence ||
          _pending!.total != total) {
        if (part != 1) {
          reset();
          return null;
        }
        _pending = _PendingPacket(sequence: sequence, total: total);
      }

      if (part != _pending!.nextPart) {
        reset();
        return null;
      }
      _pending!.buffer.write(payload);
      _pending!.nextPart++;

      if (part != total) return null;
      final document = _pending!.buffer.toString();
      reset();
      return _parseDocument(document);
    } on FormatException {
      reset();
      return null;
    }
  }

  void reset() => _pending = null;

  TelemetryFrame? _parseDocument(String document) {
    try {
      final decoded = jsonDecode(document);
      if (decoded is! Map) return null;
      final fields = Map<String, dynamic>.from(decoded);
      // Day 2 sends monotonic uptime (`u`), not a potentially false wall-clock.
      // The phone owns the observation timestamp used by the app model.
      fields['timestamp'] = DateTime.now().toUtc().toIso8601String();
      return TelemetryFrame.tryParseMap(
        fields,
        sourceType: TelemetrySourceType.ble,
        connectivity: TelemetryConnectivity.connected,
      );
    } on FormatException {
      return null;
    }
  }
}

class _PendingPacket {
  _PendingPacket({required this.sequence, required this.total});

  final int sequence;
  final int total;
  int nextPart = 1;
  final StringBuffer buffer = StringBuffer();
}
