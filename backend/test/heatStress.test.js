import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  heatIndexC,
  heatIndexExtrapolated,
  heatIndexBand,
  strainIndex,
  assessHeatStress,
  assessAirQuality,
  HI_VALID_MAX_C,
} from '../src/services/heatStress.js';

describe('heatStress Service Tests', () => {
  describe('heatIndexC', () => {
    it('returns null for null, undefined, or NaN inputs', () => {
      assert.equal(heatIndexC(null, 50), null);
      assert.equal(heatIndexC(30, null), null);
      assert.equal(heatIndexC(NaN, 50), null);
      assert.equal(heatIndexC(30, NaN), null);
      assert.equal(heatIndexC(undefined, undefined), null);
    });

    it('uses simple formula for temperatures below 80 F (~26.6 C)', () => {
      // 20 C, 50% RH
      const hi = heatIndexC(20, 50);
      assert.ok(typeof hi === 'number');
      assert.ok(hi <= 25);
    });

    it('calculates Rothfusz regression accurately for standard hot conditions', () => {
      // 35 C (~95 F), 60% RH -> known dangerous heat index
      const hi = heatIndexC(35, 60);
      assert.ok(typeof hi === 'number');
      assert.ok(hi > 40 && hi < 55);
    });

    it('applies low humidity adjustment (<13% RH, 80-112 F)', () => {
      // 35 C, 10% RH
      const hi = heatIndexC(35, 10);
      assert.ok(typeof hi === 'number');
      assert.ok(hi < 35); // Apparent temp should feel lower
    });

    it('applies high humidity adjustment (>85% RH, 80-87 F)', () => {
      // 28 C (~82.4 F), 90% RH
      const hi = heatIndexC(28, 90);
      assert.ok(typeof hi === 'number');
      assert.ok(hi > 30);
    });

    it('clamps extreme values to HI_VALID_MAX_C (58 C)', () => {
      // 48 C, 80% RH would produce absurd regression result without clamp
      const hi = heatIndexC(48, 80);
      assert.equal(hi, HI_VALID_MAX_C);
    });

    it('clamps RH to [0, 100]', () => {
      const hiNegative = heatIndexC(35, -20);
      const hiZero = heatIndexC(35, 0);
      assert.equal(hiNegative, hiZero);

      const hi150 = heatIndexC(35, 150);
      const hi100 = heatIndexC(35, 100);
      assert.equal(hi150, hi100);
    });
  });

  describe('heatIndexExtrapolated', () => {
    it('detects out-of-range temperatures', () => {
      assert.equal(heatIndexExtrapolated(null, 50), false);
      assert.equal(heatIndexExtrapolated(20, 50), true); // 68 F < 80 F
      assert.equal(heatIndexExtrapolated(35, 50), false); // 95 F (in range 80-112)
      assert.equal(heatIndexExtrapolated(50, 50), true); // 122 F > 112 F
    });
  });

  describe('heatIndexBand', () => {
    it('correctly classifies heat index bands', () => {
      assert.deepEqual(heatIndexBand(null), { level: 'unknown', label: 'Unknown', severity: null });
      assert.deepEqual(heatIndexBand(25), { level: 'safe', label: 'Safe', severity: null });
      assert.deepEqual(heatIndexBand(30), { level: 'caution', label: 'Caution', severity: 'info' });
      assert.deepEqual(heatIndexBand(35), { level: 'extreme_caution', label: 'Extreme caution', severity: 'warning' });
      assert.deepEqual(heatIndexBand(45), { level: 'danger', label: 'Danger', severity: 'warning' });
      assert.deepEqual(heatIndexBand(55), { level: 'extreme_danger', label: 'Extreme danger', severity: 'critical' });
    });
  });

  describe('strainIndex', () => {
    it('returns null if heartRate is null', () => {
      assert.equal(strainIndex(null), null);
    });

    it('computes fraction of reserve correctly', () => {
      // resting 70, max 190, reserve 120
      // HR = 70 -> strain = 0
      assert.equal(strainIndex(70, 70, 190), 0);
      // HR = 130 -> strain = (130-70)/120 = 0.5
      assert.equal(strainIndex(130, 70, 190), 0.5);
      // HR = 190 -> strain = 1.0
      assert.equal(strainIndex(190, 70, 190), 1.0);
      // HR = 50 -> strain = 0 (clamped at 0)
      assert.equal(strainIndex(50, 70, 190), 0);
    });
  });

  describe('assessHeatStress', () => {
    it('detects high cardiovascular strain in risky heat', () => {
      const assessment = assessHeatStress({
        heartRate: 140,
        ambientTemp: 38,
        humidity: 65,
        restingHr: 70,
      });

      assert.ok(assessment.severity === 'warning' || assessment.severity === 'critical');
      assert.ok(assessment.reason.includes('Heat index'));
    });

    it('reports warning for extreme danger even if body is at rest', () => {
      const assessment = assessHeatStress({
        heartRate: 60,
        ambientTemp: 46,
        humidity: 70,
        restingHr: 60,
      });

      assert.equal(assessment.band.level, 'extreme_danger');
      assert.equal(assessment.severity, 'warning');
      assert.ok(assessment.reason.includes('Exposure is unsafe'));
    });

    it('returns null severity when conditions are safe', () => {
      const assessment = assessHeatStress({
        heartRate: 72,
        ambientTemp: 24,
        humidity: 45,
        restingHr: 70,
      });

      assert.equal(assessment.severity, null);
      assert.equal(assessment.band.level, 'safe');
    });
  });

  describe('assessAirQuality', () => {
    it('returns Unknown when inputs are null', () => {
      assert.deepEqual(assessAirQuality({ aqi: null, pm25: null }), {
        severity: null,
        reason: null,
        label: 'Unknown',
      });
    });

    it('flags high respiratory risk for AQI >= 5 or PM2.5 > 120', () => {
      const r1 = assessAirQuality({ aqi: 5, pm25: 50 });
      assert.equal(r1.severity, 'warning');
      assert.equal(r1.label, 'Very poor');

      const r2 = assessAirQuality({ aqi: 3, pm25: 150 });
      assert.equal(r2.severity, 'warning');
      assert.ok(r2.reason.includes('PM2.5 150'));
    });

    it('flags info warning for AQI >= 4 or PM2.5 > 60', () => {
      const r = assessAirQuality({ aqi: 4, pm25: 75 });
      assert.equal(r.severity, 'info');
      assert.equal(r.label, 'Poor');
    });

    it('reports good air quality with no warnings', () => {
      const r = assessAirQuality({ aqi: 1, pm25: 10 });
      assert.equal(r.severity, null);
      assert.equal(r.label, 'Good');
    });
  });
});
