import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';

import ingestRoute from '../src/routes/ingest.js';
import demoRoute from '../src/routes/demo.js';
import { connectStore, listReadings, listAlerts, deleteDeviceData } from '../src/store.js';
import { resetDeviceState } from '../src/services/anomalyDetection.js';

describe('Simulator Scenarios Ingestion Tests', () => {
  let server;
  let baseUrl;
  const deviceId = 'band-sim-test';

  before(async () => {
    await connectStore();
    const app = express();
    app.use(express.json());
    app.use('/api/ingest', ingestRoute);
    app.use('/api/demo', demoRoute);

    await new Promise((resolve) => {
      server = app.listen(0, '127.0.0.1', () => {
        const port = server.address().port;
        baseUrl = `http://127.0.0.1:${port}`;
        resolve();
      });
    });
  });

  after(async () => {
    if (server) await new Promise((resolve) => server.close(resolve));
    await deleteDeviceData(deviceId, { includeProfile: true });
    resetDeviceState();
  });

  async function postSample(sample) {
    const res = await fetch(`${baseUrl}/api/ingest`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ deviceId, ...sample }),
    });
    return await res.json();
  }

  it('handles Normal scenario stream without false alarms', async () => {
    resetDeviceState(deviceId);
    for (let i = 0; i < 5; i++) {
      const res = await postSample({
        heartRate: 72,
        spo2: 98,
        ambientTemp: 28,
        humidity: 50,
        motion: 'rest',
        accelMagnitude: 1.0,
      });
      assert.equal(res.ok, true);
      assert.equal(res.alerts.length, 0);
    }
  });

  it('handles Exertion scenario and raises tachycardia after sustain window', async () => {
    resetDeviceState(deviceId);
    const start = Date.now();
    // 0s sample
    let res = await postSample({
      heartRate: 145,
      spo2: 96,
      ambientTemp: 30,
      humidity: 55,
      motion: 'active',
      accelMagnitude: 1.6,
      timestamp: new Date(start).toISOString(),
    });
    assert.equal(res.alerts.length, 0);

    // 35s sample
    res = await postSample({
      heartRate: 145,
      spo2: 96,
      ambientTemp: 30,
      humidity: 55,
      motion: 'active',
      accelMagnitude: 1.6,
      timestamp: new Date(start + 35000).toISOString(),
    });
    assert.equal(res.alerts.length, 1);
    assert.equal(res.alerts[0].type, 'tachycardia');
    assert.equal(res.alerts[0].severity, 'warning');
  });

  it('handles Hypoxia scenario and raises critical hypoxia alert immediately for SpO2 < 88', async () => {
    resetDeviceState(deviceId);
    const res = await postSample({
      heartRate: 105,
      spo2: 84,
      ambientTemp: 29,
      humidity: 55,
      motion: 'light',
      accelMagnitude: 1.15,
      timestamp: new Date().toISOString(),
    });
    assert.equal(res.alerts.length, 1);
    assert.equal(res.alerts[0].type, 'hypoxia');
    assert.equal(res.alerts[0].severity, 'critical');
  });

  it('handles Fall scenario and opens check-in', async () => {
    resetDeviceState(deviceId);
    const res = await postSample({
      heartRate: 98,
      spo2: 97,
      accelMagnitude: 3.8,
      fallDetected: true,
      timestamp: new Date().toISOString(),
    });
    assert.equal(res.alerts.length, 1);
    assert.equal(res.alerts[0].type, 'fall');
    assert.equal(res.alerts[0].severity, 'critical');
  });

  it('handles Heatwave scenario with cross-referencing', async () => {
    resetDeviceState(deviceId);
    const start = Date.now();
    // 44 C, 62% RH -> Heat index ~63 C (clamped to 58 C, extreme_danger)
    // with elevated HR 130 bpm
    const res = await postSample({
      heartRate: 130,
      spo2: 96,
      ambientTemp: 44,
      humidity: 62,
      motion: 'active',
      accelMagnitude: 1.5,
      timestamp: new Date(start).toISOString(),
    });

    assert.equal(res.reading.derived.heatBand, 'extreme_danger');
    assert.equal(res.reading.derived.heatIndex, 58);
    // Severe heat stress alert triggers
    assert.ok(res.alerts.some((a) => a.type === 'heat_stress'));
  });
});
