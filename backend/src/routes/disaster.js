import { Router } from 'express';

import config from '../config.js';
import { getDevice } from '../store.js';
import { disasterContext } from '../services/disaster/disasterContextService.js';

const router = Router();

/**
 * GET /api/disaster-context
 *
 * Official disaster context for a location, with an explicit freshness and
 * provenance label. Enrichment only — the health rules do not consult it, so
 * every failure mode here is cosmetic.
 *
 * Query: ?lat= &lon= &radiusKm= &deviceId= &limit=
 * A deviceId supplies the wearer's stored coordinates when lat/lon are absent.
 */
router.get('/', async (req, res, next) => {
  try {
    let lat = req.query.lat != null ? Number(req.query.lat) : undefined;
    let lon = req.query.lon != null ? Number(req.query.lon) : undefined;

    if ((!Number.isFinite(lat) || !Number.isFinite(lon)) && req.query.deviceId) {
      const device = await getDevice(String(req.query.deviceId));
      if (device?.lat != null && device?.lon != null) {
        lat = Number(device.lat);
        lon = Number(device.lon);
      }
    }

    const context = await disasterContext.get({
      lat,
      lon,
      radiusKm: req.query.radiusKm != null ? Number(req.query.radiusKm) : undefined,
      limit: req.query.limit != null ? Number(req.query.limit) : undefined,
    });

    res.json({ ok: true, context });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/disaster-context/refresh — force a fetch, ignoring the interval.
 * Stage scaffolding, same spirit as routes/demo.js.
 */
router.post('/refresh', async (_req, res, next) => {
  try {
    const refreshed = await disasterContext.refresh({ force: true });
    res.json({
      ok: true,
      refreshed,
      freshness: disasterContext.freshness(),
      lastError: disasterContext.lastError,
    });
  } catch (err) {
    next(err);
  }
});

/** GET /api/disaster-context/config — what this instance is configured to do. */
router.get('/config', (_req, res) => {
  res.json({
    ok: true,
    config: {
      enabled: config.disaster.enabled,
      url: config.disaster.url,
      liveWindowMinutes: Math.round(config.disaster.liveWindowMs / 60000),
      maxAgeHours: +(config.disaster.maxAgeMs / 3600000).toFixed(1),
      refreshMinutes: Math.round(config.disaster.refreshMs / 60000),
      radiusKm: config.disaster.radiusKm,
      language: config.disaster.language,
      sampleFallback: config.disaster.allowSample,
    },
  });
});

export default router;
