import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';
import 'package:swasthyashield_edge/core/telemetry/telemetry_parser.dart';

void main() {
  group('TelemetryParser', () {
    test('parses the compact replay and BLE-compatible schema', () {
      const json = '''
        {"v":1,"ts":1788249600,"hr":72.5,"spo2":98,
         "at":28.4,"rh":56,"ax":0.1,"ay":0.2,"az":1.0,
         "gx":2,"gy":3,"gz":4,"q":92,"contact":"finger","sos":0}
      ''';

      final frame = TelemetryParser.tryParseJson(
        json,
        sourceType: TelemetrySourceType.replay,
        connectivity: TelemetryConnectivity.connected,
      );

      expect(frame, isNotNull);
      expect(frame!.heartRateBpm, 72.5);
      expect(frame.spo2Percent, 98);
      expect(frame.signalQuality, 0.92);
      expect(frame.contactState, ContactState.detected);
      expect(frame.sourceType, TelemetrySourceType.replay);
      expect(frame.connectivity, TelemetryConnectivity.connected);
    });

    test('rejects malformed or incomplete packets without throwing', () {
      final malformedJson = TelemetryParser.tryParseJson(
        'this is not JSON',
        sourceType: TelemetrySourceType.replay,
        connectivity: TelemetryConnectivity.connected,
      );
      final incompleteFrame = TelemetryParser.tryParseJson(
        '{"ts":1788249600,"hr":72}',
        sourceType: TelemetrySourceType.replay,
        connectivity: TelemetryConnectivity.connected,
      );

      expect(malformedJson, isNull);
      expect(incompleteFrame, isNull);
    });

    test('keeps unsupported capabilities unavailable and validates quality', () {
      final futureCapabilityFrame = TelemetryParser.tryParseMap(
        {
          'ts': 1788249600,
          'q': 100,
          'skinTemp': 33.6,
          'pm25': 18.4,
          'battery': 83,
          'movement': true,
          'fall': false,
        },
        sourceType: TelemetrySourceType.ble,
        connectivity: TelemetryConnectivity.connected,
      );
      final invalidQuality = TelemetryParser.tryParseMap(
        {'ts': 1788249600, 'q': 101},
        sourceType: TelemetrySourceType.ble,
        connectivity: TelemetryConnectivity.connected,
      );
      final impossibleTimestamp = TelemetryParser.tryParseMap(
        {'ts': 1e100, 'q': 80},
        sourceType: TelemetrySourceType.ble,
        connectivity: TelemetryConnectivity.connected,
      );

      expect(futureCapabilityFrame, isNotNull);
      expect(futureCapabilityFrame!.skinTemperatureC, 33.6);
      expect(futureCapabilityFrame.pm25MicrogramsPerM3, 18.4);
      expect(futureCapabilityFrame.batteryPercent, 83);
      expect(futureCapabilityFrame.movementDetected, isTrue);
      expect(futureCapabilityFrame.fallDetected, isFalse);
      expect(invalidQuality, isNull);
      expect(impossibleTimestamp, isNull);
    });
  });
}
