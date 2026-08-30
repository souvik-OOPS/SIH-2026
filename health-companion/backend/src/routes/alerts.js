import { Router } from 'express';
import { listAlerts, acknowledgeAlert } from '../store.js';
import { emitAlertAck } from '../socket.js';

const router = Router();

/** GET /api/alerts/:deviceId?limit=100 */
router.get('/:deviceId', async (req, res, next) => {
  try {
    const { deviceId } = req.params;
    const limit = Math.min(Number(req.query.limit) || 100, 500);
    const rows = await listAlerts(deviceId, { limit });

    res.json({
      ok: true,
      deviceId,
      count: rows.length,
      unacknowledged: rows.filter((a) => !a.acknowledged).length,
      alerts: rows,
    });
  } catch (err) {
    next(err);
  }
});

/** POST /api/alerts/:alertId/ack — caregiver marks an alert as seen. */
router.post('/:alertId/ack', async (req, res, next) => {
  try {
    const updated = await acknowledgeAlert(req.params.alertId);
    if (!updated) return res.status(404).json({ ok: false, error: 'alert not found' });
    emitAlertAck(updated);
    res.json({ ok: true, alert: updated });
  } catch (err) {
    next(err);
  }
});

export default router;
