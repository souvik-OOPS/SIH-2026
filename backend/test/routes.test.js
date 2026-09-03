import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import cors from 'cors';

import ingestRoute from '../src/routes/ingest.js';
import historyRoute from '../src/routes/history.js';
import alertsRoute from '../src/routes/alerts.js';
import devicesRoute from '../src/routes/devices.js';
import demoRoute from '../src/routes/demo.js';
import disasterRoute from '../src/routes/disaster.js';
import safetyRoute from '../src/routes/safety.js';
import { connectStore, upsertDevice } from '../src/store.js';

function createTestApp() {
  const app = express();
  app.use(express.json());

  app.get('/api/health', (_req, res) => res.json({ ok: true, service: 'health-companion-backend' }));
  app.use('/api/ingest', ingestRoute);
  app.use('/api/history', historyRoute);
  app.use('/api/alerts', alertsRoute);
  app.use('/api/devices', devicesRoute);
  app.use('/api/demo', demoRoute);
  app.use('/api/disaster-context', disasterRoute);
  app.use('/api/safety', safetyRoute);
  return app;
}

describe('Express API Routes Integration Tests', () => {
  let server;
  let baseUrl;

  before(async () => {
    await connectStore();
    const app = createTestApp();
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
  });

  describe('GET /api/health', () => {
    it('returns healthy status', async () => {
      const res = await fetch(`${baseUrl}/api/health`);
      const body = await res.json();
      assert.equal(res.status, 200);
      assert.equal(body.ok, true);
    });
  });

  describe('POST /api/ingest', () => {
    it('rejects payload missing deviceId with 400', async () => {
      const res = await fetch(`${baseUrl}/api/ingest`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ heartRate: 75 }),
      });
      const body = await res.json();
      assert.equal(res.status, 400);
      assert.equal(body.ok, false);
      assert.ok(body.error.includes('deviceId is required'));
    });

    it('ingests valid vitals sample successfully', async () => {
      const res = await fetch(`${baseUrl}/api/ingest`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          deviceId: 'band-test-01',
          heartRate: 72,
          spo2: 98,
          ambientTemp: 28,
          humidity: 50,
          motion: 'rest',
          accelMagnitude: 1.0,
        }),
      });
      const body = await res.json();
      assert.equal(res.status, 200);
      assert.equal(body.ok, true);
      assert.equal(body.reading.deviceId, 'band-test-01');
      assert.equal(body.reading.heartRate, 72);
      assert.equal(body.reading.spo2, 98);
    });

    it('normalises out-of-range sensor readings to null', async () => {
      const res = await fetch(`${baseUrl}/api/ingest`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          deviceId: 'band-test-02',
          heartRate: 999, // Impossible HR
          spo2: -50,     // Impossible SpO2
        }),
      });
      const body = await res.json();
      assert.equal(res.status, 200);
      assert.equal(body.reading.heartRate, null);
      assert.equal(body.reading.spo2, null);
    });
  });

  describe('Safety & Privacy endpoints', () => {
    const devId = 'band-safety-01';

    before(async () => {
      await upsertDevice(devId, { wearerName: 'Safety Wearer' });
    });

    it('GET /api/safety/:deviceId/check-in', async () => {
      const res = await fetch(`${baseUrl}/api/safety/${devId}/check-in`);
      const body = await res.json();
      assert.equal(res.status, 200);
      assert.equal(body.ok, true);
      assert.equal(body.checkIn.state, 'none');
    });

    it('GET /api/safety/:deviceId/privacy', async () => {
      const res = await fetch(`${baseUrl}/api/safety/${devId}/privacy`);
      const body = await res.json();
      assert.equal(res.status, 200);
      assert.equal(body.ok, true);
      assert.ok(body.consent);
      assert.ok(body.stored);
    });

    it('DELETE /api/safety/:deviceId/data requires ?confirm=true', async () => {
      const res = await fetch(`${baseUrl}/api/safety/${devId}/data`, { method: 'DELETE' });
      const body = await res.json();
      assert.equal(res.status, 400);
      assert.equal(body.ok, false);
      assert.ok(body.error.includes('confirm=true'));
    });

    it('DELETE /api/safety/:deviceId/data deletes data with ?confirm=true', async () => {
      const res = await fetch(`${baseUrl}/api/safety/${devId}/data?confirm=true`, { method: 'DELETE' });
      const body = await res.json();
      assert.equal(res.status, 200);
      assert.equal(body.ok, true);
    });
  });

  describe('Demo endpoints', () => {
    it('POST /api/demo/env sets and returns override', async () => {
      const res = await fetch(`${baseUrl}/api/demo/env`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ preset: 'heatwave' }),
      });
      const body = await res.json();
      assert.equal(res.status, 200);
      assert.equal(body.ok, true);
      assert.equal(body.override.tempC, 44);
      assert.equal(body.override.humidity, 62);
    });

    it('POST /api/demo/reset clears state', async () => {
      const res = await fetch(`${baseUrl}/api/demo/reset`, { method: 'POST' });
      const body = await res.json();
      assert.equal(res.status, 200);
      assert.equal(body.ok, true);
    });
  });
});
