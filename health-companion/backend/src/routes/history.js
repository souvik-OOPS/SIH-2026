import { Router } from 'express';
import { listReadings } from '../store.js';
import { getBaseline } from '../services/anomalyDetection.js';

const router = Router();

/**
 * GET /api/history/:deviceId?limit=200&minutes=60
 * Returns readings oldest-first, which is the order Chart.js wants.
 */
router.get('/:deviceId', async (req, res, next) => {
  try {
    const { deviceId } = req.params;
    const limit = Math.min(Number(req.query.limit) || 200, 2000);
    const minutes = Number(req.query.minutes);
    const since = Number.isFinite(minutes) && minutes > 0 ? new Date(Date.now() - minutes * 60_000) : undefined;

    const rows = await listReadings(deviceId, { limit, since });

    res.json({
      ok: true,
      deviceId,
      count: rows.length,
      baseline: getBaseline(deviceId),
      readings: rows.slice().reverse(),
    });
  } catch (err) {
    next(err);
  }
});

export default router;
