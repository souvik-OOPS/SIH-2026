import { Router } from 'express';
import { listDevices, getDevice, upsertDevice } from '../store.js';
import {
  getBaseline,
  thresholdsFor,
  isUsableAge,
  AGE_MIN,
  AGE_MAX,
} from '../services/anomalyDetection.js';
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
      thresholds: thresholdsFor(device.profile, device.age),
      baseline: getBaseline(deviceId),
      ambient,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * PUT /api/devices/:deviceId
 * Register or update a wearer: name, vulnerability profile, age, sex,
 * emergency contact, location.
 *
 * Age and sex are optional. Age tightens the heart-rate ceiling when present;
 * sex is stored for the record but no rule keys off it, because normal heart
 * rate and SpO2 ranges do not differ enough by sex to justify a threshold.
 */
router.put('/:deviceId', async (req, res, next) => {
  try {
    const { deviceId } = req.params;
    const allowed = [
      'wearerName',
      'profile',
      'age',
      'sex',
      'emergencyContact',
      'emergencyContactName',
      'lat',
      'lon',
    ];
    const patch = {};
    for (const k of allowed) {
      if (req.body?.[k] !== undefined) patch[k] = req.body[k];
    }

    // Reject rather than silently coerce: a bad age would quietly change the
    // heart-rate ceiling, and a wrong threshold is worse than a missing one.
    if (patch.age !== undefined && patch.age !== null && !isUsableAge(patch.age)) {
      return res.status(400).json({
        ok: false,
        error: `age must be a number between ${AGE_MIN} and ${AGE_MAX}, or null`,
      });
    }
    if (
      patch.sex !== undefined &&
      patch.sex !== null &&
      !['male', 'female', 'other'].includes(patch.sex)
    ) {
      return res
        .status(400)
        .json({ ok: false, error: "sex must be 'male', 'female', 'other', or null" });
    }
    const device = await upsertDevice(deviceId, patch);
    res.json({ ok: true, device: withStatus(device) });
  } catch (err) {
    next(err);
  }
});

export default router;
