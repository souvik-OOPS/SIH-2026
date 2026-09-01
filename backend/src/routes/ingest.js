import { Router } from 'express';
import config from '../config.js';
import { saveReading, saveAlert, upsertDevice, getDevice, markAlertSms } from '../store.js';
import { evaluateReading } from '../services/anomalyDetection.js';
import { getAmbientConditions } from '../services/weatherService.js';
import { sendAlertSms } from '../services/smsService.js';
import { emitReading, emitAlert, emitAlertUpdate } from '../socket.js';

const router = Router();

/* ------------------------------- validation ------------------------------- */

const numOrNull = (v) => {
  if (v === undefined || v === null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

const inRange = (n, lo, hi) => (n == null ? null : n >= lo && n <= hi ? n : null);

/**
 * The ESP32 sends whatever its attached sensors produced. Anything missing,
 * out of physiological range, or unparseable becomes null rather than being
 * rejected — a device with a flaky MAX30102 should still report temperature.
 */
function normalise(body) {
  const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';
  if (!deviceId) return { error: 'deviceId is required' };

  let timestamp = body.timestamp ? new Date(body.timestamp) : new Date();
  if (Number.isNaN(timestamp.getTime())) timestamp = new Date();
  // An ESP32 without NTP reports epoch 1970 or drifts; trust the server clock
  // when the device clock is obviously wrong.
  const skewMs = Math.abs(Date.now() - timestamp.getTime());
  if (skewMs > 24 * 60 * 60 * 1000) timestamp = new Date();

  // accelData may arrive as {x,y,z} or as a precomputed magnitude.
  let accelMagnitude = numOrNull(body.accelMagnitude);
  const a = body.accelData;
  if (accelMagnitude == null && a && typeof a === 'object') {
    const x = numOrNull(a.x);
    const y = numOrNull(a.y);
    const z = numOrNull(a.z);
    if (x != null && y != null && z != null) {
      accelMagnitude = Math.round(Math.sqrt(x * x + y * y + z * z) * 100) / 100;
    }
  }

  let motion = body.motion;
  if (!['rest', 'light', 'active'].includes(motion)) {
    motion =
      accelMagnitude == null
        ? 'unknown'
        : Math.abs(accelMagnitude - 1) < 0.08
          ? 'rest'
          : Math.abs(accelMagnitude - 1) < 0.35
            ? 'light'
            : 'active';
  }

  return {
    reading: {
      deviceId,
      heartRate: inRange(numOrNull(body.heartRate), 25, 250),
      spo2: inRange(numOrNull(body.spo2), 50, 100),
      bodyTemp: inRange(numOrNull(body.bodyTemp), 25, 45),
      ambientTemp: inRange(numOrNull(body.ambientTemp), -30, 70),
      humidity: inRange(numOrNull(body.humidity), 0, 100),
      accelMagnitude,
      fallDetected: body.fallDetected === true || body.fallDetected === 'true',
      motion,
      signalOk: body.signalOk === undefined ? true : body.signalOk === true || body.signalOk === 'true',
      timestamp,
    },
  };
}

/* --------------------------------- route ---------------------------------- */

/**
 * POST /api/ingest
 * Body: { deviceId, heartRate, spo2, ambientTemp, humidity, accelData|accelMagnitude,
 *         fallDetected, bodyTemp, signalOk, timestamp }
 */
router.post('/', async (req, res, next) => {
  try {
    // Shared-secret check for the device. Skipped entirely when DEVICE_API_KEY
    // is blank so the simulator and a bare curl both work out of the box.
    if (config.deviceApiKey) {
      const presented = req.get('x-api-key') || req.body?.apiKey;
      if (presented !== config.deviceApiKey) {
        return res.status(401).json({ ok: false, error: 'invalid or missing x-api-key' });
      }
    }

    const { error, reading } = normalise(req.body || {});
    if (error) return res.status(400).json({ ok: false, error });

    const device = await getDevice(reading.deviceId);

    // Ambient enrichment. Never block ingestion on a slow third-party API —
    // if it isn't cached and the network is down, we proceed with device data.
    let ambient = null;
    try {
      ambient = await getAmbientConditions({ lat: device?.lat, lon: device?.lon });
    } catch {
      ambient = null;
    }

    const { alerts, derived } = evaluateReading(reading, { device, ambient });

    // The device row must exist before the reading: readings.device_id is a
    // foreign key, so a first-ever sample from a new band would be rejected
    // if this ran afterwards.
    await upsertDevice(reading.deviceId, { lastSeen: reading.timestamp });

    const stored = await saveReading({ ...reading, heatIndex: derived.heatIndex });

    const payload = { ...stored, derived, ambient };
    emitReading(payload);

    // Persist, push, and page — in that order, so a failing SMS provider can
    // never lose the alert record.
    const savedAlerts = [];
    for (const alert of alerts) {
      const savedAlert = await saveAlert(alert);
      emitAlert(savedAlert);
      savedAlerts.push(savedAlert);

      if (alert.severity === 'critical') {
        const result = await sendAlertSms(savedAlert, device);
        // Always record the outcome — an alert whose SMS was suppressed by the
        // cooldown must say so, rather than looking like nothing was attempted.
        const patch = await markAlertSms(savedAlert._id, {
          smsSent: result.sent,
          smsError: result.error,
          smsNote: result.skipped,
        });
        Object.assign(savedAlert, patch);
        emitAlertUpdate(savedAlert);
        if (config.verbose && result.skipped) console.log(`[sms] skipped: ${result.skipped}`);
      }
    }

    res.json({
      ok: true,
      reading: payload,
      alerts: savedAlerts.map((a) => ({ type: a.type, severity: a.severity, message: a.message })),
    });
  } catch (err) {
    next(err);
  }
});

export default router;
