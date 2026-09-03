import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { buildEmergencyPacket } from '../src/services/emergencyPacket.js';
import { resetDeviceState } from '../src/services/anomalyDetection.js';
import { resetNonResponse } from '../src/services/nonResponse.js';

describe('emergencyPacket Service Tests', () => {
  const deviceId = 'test-device-packet';

  beforeEach(() => {
    resetDeviceState();
    resetNonResponse();
  });

  it('builds a safe minimal emergency packet even with empty inputs', () => {
    const packet = buildEmergencyPacket({ deviceId });

    assert.equal(packet.deviceId, deviceId);
    assert.equal(packet.event, null);
    assert.equal(packet.location, null);
    assert.equal(packet.disasterContext, null);
    assert.equal(packet.notes.generatedOffline, true);
    assert.ok(packet.generatedAt);
  });

  it('calculates heart rate and spo2 trends correctly', () => {
    const recent = [
      { heartRate: 70, spo2: 98 },
      { heartRate: 72, spo2: 97 },
      { heartRate: 75, spo2: 96 },
      { heartRate: 80, spo2: 94 },
      { heartRate: 88, spo2: 92 },
      { heartRate: 95, spo2: 90 },
    ];

    const packet = buildEmergencyPacket({
      deviceId,
      reading: recent[recent.length - 1],
      recent,
    });

    assert.equal(packet.recentTrend.heartRate.direction, 'rising');
    assert.equal(packet.recentTrend.heartRate.from, 70);
    assert.equal(packet.recentTrend.heartRate.to, 95);

    assert.equal(packet.recentTrend.spo2.direction, 'falling');
    assert.equal(packet.recentTrend.spo2.from, 98);
    assert.equal(packet.recentTrend.spo2.to, 90);
  });

  it('includes coordinates only when present on device record', () => {
    const packetNoLoc = buildEmergencyPacket({
      deviceId,
      device: { wearerName: 'Test Wearer' },
    });
    assert.equal(packetNoLoc.location, null);

    const packetWithLoc = buildEmergencyPacket({
      deviceId,
      device: { wearerName: 'Test Wearer', lat: 12.9716, lon: 77.5946 },
    });
    assert.deepEqual(packetWithLoc.location, {
      lat: 12.9716,
      lon: 77.5946,
      source: 'device record',
    });
  });
});
