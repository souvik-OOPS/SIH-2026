import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  evaluateFall,
  resetFallState,
  angleBetween,
  getFallState,
} from '../src/services/fallDetection.js';

describe('fallDetection Service Tests', () => {
  beforeEach(() => {
    resetFallState();
  });

  describe('angleBetween', () => {
    it('returns null for missing vectors or zero vectors', () => {
      assert.equal(angleBetween(null, { x: 0, y: 0, z: 1 }), null);
      assert.equal(angleBetween({ x: 0, y: 0, z: 0 }, { x: 0, y: 0, z: 1 }), null);
    });

    it('calculates 0 degrees for identical vectors', () => {
      const a = { x: 0, y: 0, z: 1 };
      const b = { x: 0, y: 0, z: 1 };
      assert.equal(Math.round(angleBetween(a, b)), 0);
    });

    it('calculates 90 degrees for orthogonal vectors', () => {
      const a = { x: 1, y: 0, z: 0 };
      const b = { x: 0, y: 1, z: 0 };
      assert.equal(Math.round(angleBetween(a, b)), 90);
    });

    it('calculates 180 degrees for opposite vectors', () => {
      const a = { x: 0, y: 0, z: 1 };
      const b = { x: 0, y: 0, z: -1 };
      assert.equal(Math.round(angleBetween(a, b)), 180);
    });
  });

  describe('evaluateFall', () => {
    const deviceId = 'test-device-fall';

    it('immediately accepts device-side fall detection', () => {
      const result = evaluateFall({
        deviceId,
        fallDetected: true,
        accelMagnitude: 1.0,
      });

      assert.equal(result.fall, true);
      assert.equal(result.confidence, 1);
      assert.equal(result.source, 'device');
    });

    it('ignores normal resting/walking motion', () => {
      const baseTime = 1000000;
      for (let i = 0; i < 10; i++) {
        const res = evaluateFall({
          deviceId,
          accelMagnitude: 1.0 + (i % 2 === 0 ? 0.05 : -0.05),
          timestamp: new Date(baseTime + i * 1000).toISOString(),
        });
        assert.equal(res.fall, false);
      }
    });

    it('does not trigger a fall on a high impact knock followed by movement', () => {
      const baseTime = 1000000;
      // Normal motion
      evaluateFall({
        deviceId,
        accelMagnitude: 1.0,
        accel: { x: 0, y: 0, z: 1 },
        timestamp: new Date(baseTime).toISOString(),
      });
      // Knock (3.5g)
      evaluateFall({
        deviceId,
        accelMagnitude: 3.5,
        accel: { x: 2, y: 2, z: 2 },
        timestamp: new Date(baseTime + 200).toISOString(),
      });
      // Continues moving (not still)
      const res = evaluateFall({
        deviceId,
        accelMagnitude: 1.6,
        timestamp: new Date(baseTime + 1000).toISOString(),
      });
      assert.equal(res.fall, false);
    });

    it('detects a full fall sequence: Free Fall -> Impact -> Orientation Change -> Stillness', () => {
      let t = 1000000;
      // Pre-impact standing
      evaluateFall({
        deviceId,
        accelMagnitude: 1.0,
        accel: { x: 0, y: 0, z: 1 },
        timestamp: new Date(t).toISOString(),
      });

      // Free fall (0.2g)
      t += 200;
      evaluateFall({
        deviceId,
        accelMagnitude: 0.2,
        accel: { x: 0, y: 0, z: 0.2 },
        timestamp: new Date(t).toISOString(),
      });

      // Impact (3.2g)
      t += 300;
      evaluateFall({
        deviceId,
        accelMagnitude: 3.2,
        accel: { x: 2.5, y: 1.5, z: 1 },
        timestamp: new Date(t).toISOString(),
      });

      // Lying down (orientation change ~90 deg) and still (1.0g) for 2.0s
      // Stillness checks at intervals
      t += 500;
      let res = evaluateFall({
        deviceId,
        accelMagnitude: 1.0,
        accel: { x: 1, y: 0, z: 0 }, // 90 deg from {0,0,1}
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(res.fall, false); // Stillness hasn't reached 2.0s

      t += 2100; // 2.1s later of stillness
      res = evaluateFall({
        deviceId,
        accelMagnitude: 1.0,
        accel: { x: 1, y: 0, z: 0 },
        timestamp: new Date(t).toISOString(),
      });

      assert.equal(res.fall, true);
      assert.equal(res.source, 'telemetry');
      assert.equal(res.stages.freeFall, true);
      assert.equal(res.stages.impact, true);
      assert.equal(res.stages.orientation, true);
      assert.equal(res.stages.stillness, true);
      assert.equal(res.confidence, 1.0); // 0.6 + 0.2 + 0.2
    });

    it('detects sitting fall without free fall (lower confidence)', () => {
      let t = 1000000;
      // Normal sitting
      evaluateFall({
        deviceId,
        accelMagnitude: 1.0,
        timestamp: new Date(t).toISOString(),
      });

      // Impact directly (2.8g)
      t += 500;
      evaluateFall({
        deviceId,
        accelMagnitude: 2.8,
        timestamp: new Date(t).toISOString(),
      });

      // Stillness for >2s
      t += 500;
      evaluateFall({
        deviceId,
        accelMagnitude: 1.0,
        timestamp: new Date(t).toISOString(),
      });

      t += 2100;
      const res = evaluateFall({
        deviceId,
        accelMagnitude: 1.0,
        timestamp: new Date(t).toISOString(),
      });

      assert.equal(res.fall, true);
      assert.equal(res.stages.freeFall, false);
      assert.equal(res.stages.impact, true);
      assert.equal(res.stages.stillness, true);
      assert.equal(res.confidence, 0.6); // 0.6 base
    });

    it('resets to idle if verification window exceeds 4000ms', () => {
      let t = 1000000;
      // Impact
      evaluateFall({
        deviceId,
        accelMagnitude: 3.0,
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(getFallState(deviceId).phase, 'impacted');

      // 13 seconds pass with erratic motion (> 12s verificationMs)
      t += 13000;
      const res = evaluateFall({
        deviceId,
        accelMagnitude: 1.0,
        timestamp: new Date(t).toISOString(),
      });

      assert.equal(res.fall, false);
      assert.equal(getFallState(deviceId).phase, 'idle');
    });
  });
});
