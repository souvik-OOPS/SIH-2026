import { Router } from 'express';
import { listDevices, getDevice, upsertDevice } from '../store.js';
import { getBaseline, thresholdsFor } from '../services/anomalyDetection.js';
import { getAmbientConditions } from '../services/weatherService.js';

const router = Router();

// A device is considered offline after this long without a reading.
const OFFLINE_AFTER_MS = 30_000;

const withStatus = (d) => ({
  ...d,
  online: d.lastSeen ? Date.now() - new Date(d.lastSeen).getTime() < OFFLINE_AFTER_MS : false,
});

/** GET /api/devices */
router.get('/', async (_req, res, next) => {
  try {
    const rows = await listDevices();
    res.json({ ok: true, count: rows.length, devices: rows.map(withStatus) });
  } catch (err) {
    next(err);
  }
});

/** GET /api/devices/:deviceId — profile, thresholds in force, learned baseline, ambient. */
router.get('/:deviceId', async (req, res, next) => {
  try {
    const { deviceId } = req.params;
    const device = await getDevice(deviceId);
    if (!device) return res.status(404).json({ ok: false, error: 'device not registered' });

    const ambient = await getAmbientConditions({ lat: device.lat, lon: device.lon }).catch(() => null);

    res.json({
      ok: true,
      device: withStatus(device),
      thresholds: thresholdsFor(device.profile),
      baseline: getBaseline(deviceId),
      ambient,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * PUT /api/devices/:deviceId
 * Register or update a wearer: name, vulnerability profile, emergency contact, location.
 */
router.put('/:deviceId', async (req, res, next) => {
  try {
    const { deviceId } = req.params;
    const allowed = ['wearerName', 'profile', 'emergencyContact', 'emergencyContactName', 'lat', 'lon'];
    const patch = {};
    for (const k of allowed) {
      if (req.body?.[k] !== undefined) patch[k] = req.body[k];
    }
    const device = await upsertDevice(deviceId, patch);
    res.json({ ok: true, device: withStatus(device) });
  } catch (err) {
    next(err);
  }
});

export default router;
