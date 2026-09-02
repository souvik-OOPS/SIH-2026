import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/services/ble_packet_assembler.dart';

/// Replays a real packet captured from the ESP32 serial monitor through the
/// exact fragmenting the firmware performs, to find where a live frame is lost
/// between the radio and the dashboard.
void main() {
  // Copied verbatim from the hardware serial log.
  const live =
      '{"v":1,"u":206600,"hr":null,"o2":null,"t":30.9,"h":89.9,"ax":0.04,'
      '"ay":0.01,"az":1.04,"gx":-1.1,"gy":0.0,"gz":0.0,"q":0,"f":0}';

  /// Mirrors notifyFragments(): 7 JSON bytes per notification behind an
  /// "@seq,part/total:" header.
  List<List<int>> fragment(String json, {int sequence = 42}) {
    const dataBytes = 7;
    final total = (json.length + dataBytes - 1) ~/ dataBytes;
    return List.generate(total, (i) {
      final start = i * dataBytes;
      final end = (start + dataBytes).clamp(0, json.length);
      final chunk = json.substring(start, end);
      return utf8.encode('@$sequence,${i + 1}/$total:$chunk');
    });
  }

  test('the live packet survives fragment reassembly', () {
    final assembler = BlePacketAssembler();
    final parts = fragment(live);

    TelemetryFrame? out;
    for (final p in parts) {
      final f = assembler.accept(p);
      if (f != null) out = f;
    }

    expect(parts.length, greaterThan(1));
    expect(out, isNotNull,
        reason: 'reassembly produced no frame from ${parts.length} fragments');
  });

  test('every notification stays inside the 20-byte default ATT payload', () {
    for (final p in fragment(live)) {
      expect(p.length, lessThanOrEqualTo(20),
          reason: 'fragment too long: ${utf8.decode(p)}');
    }
  });

  // hr/o2 null and q:0 is what the band sends with no finger on the sensor.
  // It must still produce a frame: blanking the vitals is correct, showing
  // nothing at all is the bug that leaves the dashboard on a spinner.
  test('a finger-off packet still yields a usable frame', () {
    final assembler = BlePacketAssembler();
    TelemetryFrame? out;
    for (final p in fragment(live)) {
      final f = assembler.accept(p);
      if (f != null) out = f;
    }
    expect(out, isNotNull);
    expect(out!.heartRateBpm, isNull);
    expect(out.spo2Percent, isNull);
    expect(out.ambientTemperatureC, closeTo(30.9, 0.01));
  });
}
