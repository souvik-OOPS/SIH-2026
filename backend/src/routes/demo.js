import { Router } from 'express';
import { setWeatherOverride, clearWeatherOverride, getWeatherOverride } from '../services/weatherService.js';
import { resetDeviceState } from '../services/anomalyDetection.js';
import { storeStatus } from '../store.js';

const router = Router();

/**
 * Stage controls for the demo. Kept in their own route file so it is obvious
 * what is demo scaffolding and what is the product — and so the whole thing
 * can be dropped by removing one app.use() line.
 *
 * The demo script needs to show a heat-stress alert without waiting for an
 * actual heatwave, so this lets you push a fake ambient payload at the
 * anomaly engine live, no restart.
 */

/** GET /api/demo/env — what ambient override, if any, is currently forced. */
router.get('/env', (_req, res) => {
  res.json({ ok: true, override: getWeatherOverride(), store: storeStatus() });
});

/**
 * POST /api/demo/env
 * Body: { tempC, humidity, aqi, pm25 }  — or { preset: 'heatwave' | 'pollution' | 'flood' }
 */
router.post('/env', (req, res) => {
  const presets = {
    heatwave: { tempC: 44, humidity: 62, aqi: 3, pm25: 74, description: 'heatwave (simulated)' },
    pollution: { tempC: 29, humidity: 55, aqi: 5, pm25: 168, description: 'severe smog (simulated)' },
    flood: { tempC: 31, humidity: 94, aqi: 2, pm25: 28, description: 'post-flood humidity (simulated)' },
    normal: { tempC: 29, humidity: 55, aqi: 2, pm25: 32, description: 'normal (simulated)' },
  };

  const body = req.body || {};
  const payload = body.preset ? presets[body.preset] : body;

  if (!payload) {
    return res.status(400).json({ ok: false, error: `unknown preset. Use one of: ${Object.keys(presets).join(', ')}` });
  }

  const override = setWeatherOverride({ ...payload, source: 'demo-override' });
  res.json({ ok: true, override });
});

/** DELETE /api/demo/env — back to the real weather API (or on-device sensors). */
router.delete('/env', (_req, res) => {
  clearWeatherOverride();
  res.json({ ok: true, override: null });
});

/**
 * POST /api/demo/reset/:deviceId
 * Clears learned baseline, sustain timers and alert cooldowns so you can run
 * the same demo twice in a row without waiting out a cooldown.
 */
router.post('/reset/:deviceId?', (req, res) => {
  resetDeviceState(req.params.deviceId);
  res.json({ ok: true, reset: req.params.deviceId || 'all devices' });
});

export default router;
