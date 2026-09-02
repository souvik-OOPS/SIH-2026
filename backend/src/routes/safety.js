import { Router } from 'express';

import config from '../config.js';
import {
  getDevice,
  recentReadings,
  summariseStoredData,
  deleteDeviceData,
} from '../store.js';
import {
  getBaseline,
  resetDeviceState,
  evaluateReading,
} from '../services/anomalyDetection.js';
import { checkInStatus, respondOk, clearCheckIn } from '../services/nonResponse.js';
import { assessRisk } from '../services/riskEngine.js';
import { buildEmergencyPacket } from '../services/emergencyPacket.js';
import { disasterContext } from '../services/disaster/disasterContextService.js';

const router = Router();

/**
 * Safety loop: check-in state, the "I'm OK" response, the emergency packet,
 * and the privacy controls.
 *
 * Every route here works with no internet. The only outward-facing thing is
 * cached disaster context, which is read from memory and never fetched while
 * building a packet.
 */

/** GET /api/safety/:deviceId/check-in — countdown state for the UI. */
router.get('/:deviceId/check-in', (req, res) => {
  const status = checkInStatus(req.params.deviceId);
  res.json({ ok: true, checkIn: status });
});

/**
 * POST /api/safety/:deviceId/respond-ok — the wearer pressed "I'M OK".
 *
 * Refused once the window has closed, because by then an escalation may have
 * gone out and quietly marking it resolved would leave a responder believing
 * the alert was retracted when nobody told them.
 */
router.post('/:deviceId/respond-ok', (req, res) => {
  const result = respondOk(req.params.deviceId);
  if (!result.ok) {
    return res.status(409).json({ ok: false, error: result.reason, checkIn: result.status ?? null });
  }
  res.json({ ok: true, checkIn: result.status });
});

/** POST /api/safety/:deviceId/clear-check-in — dismiss a closed incident. */
router.post('/:deviceId/clear-check-in', (req, res) => {
  const cleared = clearCheckIn(req.params.deviceId);
  res.json({ ok: cleared, checkIn: checkInStatus(req.params.deviceId) });
});

/**
 * GET /api/safety/:deviceId/emergency-packet
 *
 * Builds the responder summary from what is already held locally. Generating
 * it asserts nothing about delivery — the packet says so itself.
 */
router.get('/:deviceId/emergency-packet', async (req, res, next) => {
  try {
    const { deviceId } = req.params;
    const device = await getDevice(deviceId);
    const recent = await recentReadings(deviceId, 10 * 60 * 1000);
    const latest = recent[recent.length - 1] ?? {};

    // Re-run the rules on the latest sample so the packet reflects the same
    // logic the dashboard shows, rather than a separately-derived opinion.
    const { alerts, derived } = latest.deviceId
      ? evaluateReading(latest, { device })
      : { alerts: [], derived: {} };

    const risk = assessRisk({
      alerts,
      reading: latest,
      derived,
      nonResponse: checkInStatus(deviceId),
      disaster: disasterContext.cache.alerts ? disasterContext.describe() : null,
    });

    const packet = buildEmergencyPacket({
      deviceId,
      device,
      reading: latest,
      derived,
      risk,
      recent,
      disaster: disasterContext.cache.alerts ? disasterContext.describe() : null,
    });

    res.json({ ok: true, packet });
  } catch (err) {
    next(err);
  }
});

/* -------------------------------- privacy -------------------------------- */

/** GET /api/safety/:deviceId/privacy — what is stored, and what it is for. */
router.get('/:deviceId/privacy', async (req, res, next) => {
  try {
    const { deviceId } = req.params;
    const stored = await summariseStoredData(deviceId);
    const baseline = getBaseline(deviceId);

    res.json({
      ok: true,
      stored,
      baseline: {
        restingHr: baseline.restingHr == null ? null : Math.round(baseline.restingHr),
        samples: baseline.samples,
        ready: baseline.ready,
        note: 'Learned on this server from your at-rest readings. It never leaves it.',
      },
      consent: {
        whatIsCollected:
          'Heart rate, blood oxygen, ambient temperature and humidity, and movement from the wearable.',
        whyItIsCollected:
          'To detect falls and dangerous vital signs, and to learn your normal resting heart rate so alerts fit you rather than an average.',
        whereItIsStored:
          stored.storage === 'memory'
            ? 'In this server’s memory only. It is lost when the server stops.'
            : 'In the configured database for this deployment.',
        whatLeavesTheDevice:
          'Nothing automatically. An emergency SMS is sent only when an alert escalates, and only to the contacts you entered.',
        retention:
          'Kept until you delete it. There is no automatic upload and no third-party analytics.',
        yourControls:
          'You can clear the learned baseline, or delete all stored readings and alerts, at any time.',
      },
    });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/safety/:deviceId/clear-baseline
 *
 * Drops the learned resting rate and every in-memory detector timer. The next
 * readings start teaching it again from scratch.
 */
router.post('/:deviceId/clear-baseline', (req, res) => {
  resetDeviceState(req.params.deviceId);
  res.json({
    ok: true,
    baseline: getBaseline(req.params.deviceId),
    note: 'Learned baseline, alert timers and fall state cleared for this device.',
  });
});

/**
 * DELETE /api/safety/:deviceId/data — erase stored health data.
 *
 * Requires ?confirm=true so a stray request cannot wipe a wearer's history.
 * `?includeProfile=true` also removes the device record and its emergency
 * contacts; without it the band stays registered.
 */
router.delete('/:deviceId/data', async (req, res, next) => {
  try {
    if (req.query.confirm !== 'true') {
      return res.status(400).json({
        ok: false,
        error: 'Add ?confirm=true to delete stored health data. This cannot be undone.',
      });
    }
    const { deviceId } = req.params;
    const includeProfile = req.query.includeProfile === 'true';

    const deleted = await deleteDeviceData(deviceId, { includeProfile });
    resetDeviceState(deviceId);

    res.json({
      ok: true,
      deleted,
      note: includeProfile
        ? 'Readings, alerts, the learned baseline and the device record were deleted.'
        : 'Readings, alerts and the learned baseline were deleted. The device record was kept.',
    });
  } catch (err) {
    next(err);
  }
});

/** GET /api/safety/config — the thresholds in force, for the review. */
router.get('/config', (_req, res) => {
  res.json({
    ok: true,
    fall: {
      freeFallG: config.fall.freeFallG,
      impactG: config.fall.impactG,
      orientationDeg: config.fall.orientationDeg,
      stillnessBandG: config.fall.stillnessBandG,
      stillnessSeconds: config.fall.stillnessMs / 1000,
      verificationSeconds: config.fall.verificationMs / 1000,
      responseWindowSeconds: config.fall.responseWindowMs / 1000,
    },
  });
});

export default router;
