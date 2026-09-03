import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  evaluateReading,
  resetDeviceState,
  getBaseline,
  thresholdsFor,
  isUsableAge,
} from '../src/services/anomalyDetection.js';

describe('anomalyDetection Service Tests', () => {
  const deviceId = 'test-device-anomaly';

  beforeEach(() => {
    resetDeviceState();
  });

  describe('thresholdsFor and age adjustments', () => {
    it('validates usable age', () => {
      assert.equal(isUsableAge(null), false);
      assert.equal(isUsableAge(undefined), false);
      assert.equal(isUsableAge('25'), false);
      assert.equal(isUsableAge(-5), false);
      assert.equal(isUsableAge(0), false);
      assert.equal(isUsableAge(150), false);
      assert.equal(isUsableAge(25), true);
      assert.equal(isUsableAge(75), true);
    });

    it('returns default profile bounds when age is absent', () => {
      const general = thresholdsFor('general');
      assert.equal(general.hrHigh, 120);
      assert.equal(general.spo2Low, 92);
      assert.equal(general.hrHighSource, 'profile');

      const elderly = thresholdsFor('elderly');
      assert.equal(elderly.hrHigh, 110);
      assert.equal(elderly.spo2Low, 93);
    });

    it('tightens hrHigh for older adults (Tanaka formula) but never raises above profile', () => {
      // 75 year old: Tanaka HRmax = 208 - 0.7 * 75 = 155.5; 70% of HRmax = ~109 bpm
      const t75 = thresholdsFor('general', 75);
      assert.equal(t75.hrHigh, 109);
      assert.equal(t75.hrHighSource, 'age');

      // 20 year old: Tanaka HRmax = 208 - 14 = 194; 70% = 136 bpm (higher than 120 base)
      // Rule says age can only tighten, never raise.
      const t20 = thresholdsFor('general', 20);
      assert.equal(t20.hrHigh, 120);
      assert.equal(t20.hrHighSource, 'profile');
    });
  });

  describe('Resting HR Baseline Learning', () => {
    it('learns resting baseline through EWMA during rest samples', () => {
      let t = 1000000;
      for (let i = 0; i < 70; i++) {
        t += 1000;
        evaluateReading({
          deviceId,
          heartRate: 60,
          motion: 'rest',
          accelMagnitude: 1.0,
          signalOk: true,
          timestamp: new Date(t).toISOString(),
        });
      }

      const baseline = getBaseline(deviceId);
      assert.equal(baseline.ready, true);
      assert.ok(baseline.samples >= 60);
      assert.equal(Math.round(baseline.restingHr), 60);
    });

    it('ignores active motion or noisy samples during baseline learning', () => {
      let t = 1000000;
      for (let i = 0; i < 30; i++) {
        t += 1000;
        evaluateReading({
          deviceId,
          heartRate: 150,
          motion: 'active',
          accelMagnitude: 1.6,
          signalOk: true,
          timestamp: new Date(t).toISOString(),
        });
      }
      const baseline = getBaseline(deviceId);
      assert.equal(baseline.restingHr, null);
    });

    it('freezes baseline updates during acute excursions once ready', () => {
      let t = 1000000;
      // Learn baseline at 55 bpm
      for (let i = 0; i < 65; i++) {
        t += 1000;
        evaluateReading({
          deviceId,
          heartRate: 55,
          motion: 'rest',
          accelMagnitude: 1.0,
          signalOk: true,
          timestamp: new Date(t).toISOString(),
        });
      }
      const baseBefore = getBaseline(deviceId).restingHr;

      // High excursion at rest (95 bpm, > 55 + 30)
      for (let i = 0; i < 30; i++) {
        t += 1000;
        evaluateReading({
          deviceId,
          heartRate: 95,
          motion: 'rest',
          accelMagnitude: 1.0,
          signalOk: true,
          timestamp: new Date(t).toISOString(),
        });
      }
      const baseAfter = getBaseline(deviceId).restingHr;
      assert.equal(Math.round(baseBefore), Math.round(baseAfter));
    });
  });

  describe('Vitals Anomaly Rules', () => {
    it('triggers critical hypoxia immediately when SpO2 < spo2Critical (< 88%)', () => {
      const now = new Date(1000000).toISOString();
      const { alerts } = evaluateReading({
        deviceId,
        heartRate: 75,
        spo2: 85,
        signalOk: true,
        timestamp: now,
      });

      assert.equal(alerts.length, 1);
      assert.equal(alerts[0].type, 'hypoxia');
      assert.equal(alerts[0].severity, 'critical');
    });

    it('triggers hypoxia only after sustain window (30s) when spo2Low <= SpO2 < spo2Critical', () => {
      let t = 1000000;
      // First low sample (90%)
      let res = evaluateReading({
        deviceId,
        heartRate: 75,
        spo2: 90,
        signalOk: true,
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(res.alerts.length, 0);

      // 10s later
      t += 10000;
      res = evaluateReading({
        deviceId,
        heartRate: 75,
        spo2: 90,
        signalOk: true,
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(res.alerts.length, 0);

      // 31s later (total > 30s)
      t += 21000;
      res = evaluateReading({
        deviceId,
        heartRate: 75,
        spo2: 90,
        signalOk: true,
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(res.alerts.length, 1);
      assert.equal(res.alerts[0].type, 'hypoxia');
      assert.equal(res.alerts[0].severity, 'critical');
    });

    it('triggers tachycardia only after sustain window when HR > hrHigh', () => {
      let t = 1000000;
      // High sample (135 bpm)
      let res = evaluateReading({
        deviceId,
        heartRate: 135,
        spo2: 98,
        signalOk: true,
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(res.alerts.length, 0);

      // 31s later
      t += 31000;
      res = evaluateReading({
        deviceId,
        heartRate: 135,
        spo2: 98,
        signalOk: true,
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(res.alerts.length, 1);
      assert.equal(res.alerts[0].type, 'tachycardia');
      assert.equal(res.alerts[0].severity, 'warning');
    });

    it('triggers bradycardia only after sustain window when HR < hrLow', () => {
      let t = 1000000;
      // Low sample (40 bpm)
      let res = evaluateReading({
        deviceId,
        heartRate: 40,
        spo2: 98,
        signalOk: true,
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(res.alerts.length, 0);

      // 31s later
      t += 31000;
      res = evaluateReading({
        deviceId,
        heartRate: 40,
        spo2: 98,
        signalOk: true,
        timestamp: new Date(t).toISOString(),
      });
      assert.equal(res.alerts.length, 1);
      assert.equal(res.alerts[0].type, 'bradycardia');
      assert.equal(res.alerts[0].severity, 'warning');
    });

    it('suppresses vitals alerts when signalOk is false', () => {
      let t = 1000000;
      for (let i = 0; i < 40; i++) {
        t += 1000;
        const res = evaluateReading({
          deviceId,
          heartRate: 160,
          spo2: 70,
          signalOk: false, // Motion corruption
          timestamp: new Date(t).toISOString(),
        });
        assert.equal(res.alerts.length, 0);
      }
    });

    it('enforces alert cooldowns', () => {
      const t1 = 1000000;
      // Immediate critical hypoxia
      const res1 = evaluateReading({
        deviceId,
        heartRate: 75,
        spo2: 80,
        signalOk: true,
        timestamp: new Date(t1).toISOString(),
      });
      assert.equal(res1.alerts.length, 1);

      // 10s later (still in 60s cooldown)
      const res2 = evaluateReading({
        deviceId,
        heartRate: 75,
        spo2: 80,
        signalOk: true,
        timestamp: new Date(t1 + 10000).toISOString(),
      });
      assert.equal(res2.alerts.length, 0);

      // 65s later (cooldown expired)
      const res3 = evaluateReading({
        deviceId,
        heartRate: 75,
        spo2: 80,
        signalOk: true,
        timestamp: new Date(t1 + 65000).toISOString(),
      });
      assert.equal(res3.alerts.length, 1);
    });
  });
});
