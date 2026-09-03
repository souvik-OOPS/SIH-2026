import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { scoreReading, resetMlBuffer } from '../src/services/mlDetector.js';
import { createModel } from '../src/ml/anomalyModel.js';

describe('mlDetector & anomalyModel Tests', () => {
  const deviceId = 'test-ml-device';

  beforeEach(() => {
    resetMlBuffer(deviceId);
  });

  describe('anomalyModel forward pass', () => {
    it('creates model and computes reconstruction error for full window', () => {
      // 2 features, window 3
      const spec = {
        features: ['HR', 'SpO2'],
        window: 3,
        normalisation: { mean: [80, 97], std: [10, 2] },
        threshold: 0.5,
        layers: [
          {
            in: 6,
            out: 4,
            W: Array(24).fill(0.1),
            b: Array(4).fill(0.0),
          },
          {
            in: 4,
            out: 6,
            W: Array(24).fill(0.1),
            b: Array(6).fill(0.0),
          },
        ],
        activations: ['relu', 'none'],
      };

      const model = createModel(spec);
      const input = [
        { HR: 80, SpO2: 97 },
        { HR: 82, SpO2: 96 },
        { HR: 79, SpO2: 98 },
      ];

      const res = model.score(input);
      assert.ok(typeof res.score === 'number');
      assert.ok(typeof res.ratio === 'number');
      assert.ok(typeof res.anomalous === 'boolean');
    });

    it('handles division by zero in normalisation (std = 0) safely', () => {
      const spec = {
        features: ['HR', 'SpO2'],
        window: 2,
        normalisation: { mean: [80, 97], std: [0, 0] }, // std = 0 edge condition
        threshold: 0.5,
        layers: [
          {
            in: 4,
            out: 4,
            W: Array(16).fill(0.1),
            b: Array(4).fill(0.0),
          },
        ],
        activations: ['none'],
      };

      const model = createModel(spec);
      const input = [
        { HR: 80, SpO2: 97 },
        { HR: 80, SpO2: 97 },
      ];

      const res = model.score(input);
      assert.ok(typeof res.score === 'number');
      assert.ok(!Number.isNaN(res.score));
    });
  });

  describe('scoreReading buffer and integration', () => {
    it('returns null when buffer is not yet full', () => {
      const res = scoreReading({ deviceId, heartRate: 75, spo2: 98, signalOk: true });
      // Needs 30 samples to fill buffer
      assert.equal(res, null);
    });

    it('ignores readings with invalid signal', () => {
      const res = scoreReading({ deviceId, heartRate: 75, spo2: 98, signalOk: false });
      assert.equal(res, null);
    });
  });
});
