import 'package:flutter_test/flutter_test.dart';
import 'package:swasthyashield_edge/core/models/telemetry_frame.dart';

void main() {
  group('TelemetryFrame parsing', () {
    test('parses the compact replay and BLE-compatible schema', () {
      const json = '''
        {"v":1,"ts":1788249600,"hr":72.5,"spo2":98,
         "at":28.4,"rh":56,"ax":0.1,"ay":0.2,"az":1.0,
         "gx":2,"gy":3,"gz":4,"q":92,"contact":"finger","sos":0}
      ''';

      final frame = TelemetryFrame.tryParseJson(
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
      final malformedJson = TelemetryFrame.tryParseJson(
        'this is not JSON',
        sourceType: TelemetrySourceType.replay,
        connectivity: TelemetryConnectivity.connected,
      );
      final incompleteFrame = TelemetryFrame.tryParseJson(
        '{"ts":1788249600,"hr":72}',
        sourceType: TelemetrySourceType.replay,
        connectivity: TelemetryConnectivity.connected,
      );

      expect(malformedJson, isNull);
      expect(incompleteFrame, isNull);
    });
  });
}
