import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/services/ble_packet_assembler.dart';

void main() {
  test('reassembles a framed BLE telemetry document', () {
    const document =
        '{"v":1,"u":18342,"hr":78.4,"o2":97,"t":31.4,"h":67,"ax":0.1,"ay":0,"az":0.98,"gx":1.2,"gy":0.4,"gz":0.3,"q":92,"f":1}';
    final fragments = _frame(document, sequence: 42);
    final assembler = BlePacketAssembler();

    for (var index = 0; index < fragments.length - 1; index++) {
      expect(assembler.accept(utf8.encode(fragments[index])), isNull);
    }
    final frame = assembler.accept(utf8.encode(fragments.last));

    expect(frame, isNotNull);
    expect(frame!.heartRateBpm, 78.4);
    expect(frame.spo2Percent, 97);
    expect(frame.ambientTemperatureC, 31.4);
    expect(frame.signalQuality, 0.92);
    expect(frame.contactState, ContactState.detected);
  });

  test('keeps a frame when an unavailable sensor is encoded as null', () {
    const document =
        '{"v":1,"u":18342,"hr":null,"o2":null,"t":null,"h":null,"ax":null,"ay":null,"az":null,"gx":null,"gy":null,"gz":null,"q":0,"f":0}';
    final assembler = BlePacketAssembler();

    final frame = assembler.accept(utf8.encode(document));

    expect(frame, isNotNull);
    expect(frame!.ambientTemperatureC, isNull);
    expect(frame.humidityPercent, isNull);
    expect(frame.accelerometerMagnitude, isNull);
    expect(frame.contactState, ContactState.noFinger);
  });

  test('drops an out-of-sequence partial frame without throwing', () {
    final assembler = BlePacketAssembler();

    expect(assembler.accept(utf8.encode('@7,1/2:{"v":1')), isNull);
    expect(assembler.accept(utf8.encode('@7,3/2:}')), isNull);
    expect(assembler.accept(utf8.encode('not a packet')), isNull);
  });
}

List<String> _frame(String document, {required int sequence}) {
  const payloadSize = 7;
  final total = (document.length + payloadSize - 1) ~/ payloadSize;
  return List<String>.generate(total, (index) {
    final offset = index * payloadSize;
    final end = (offset + payloadSize).clamp(0, document.length).toInt();
    return '@$sequence,${index + 1}/$total:${document.substring(offset, end)}';
  });
}
