import http from 'node:http';
import express from 'express';
import cors from 'cors';

import config from './config.js';
import { connectStore, storeStatus, upsertDevice, closeStore } from './store.js';
import { mlStatus } from './services/mlDetector.js';
import { initSocket } from './socket.js';

import ingestRoute from './routes/ingest.js';
import historyRoute from './routes/history.js';
import alertsRoute from './routes/alerts.js';
import devicesRoute from './routes/devices.js';
import demoRoute from './routes/demo.js';

const app = express();

app.use(cors({ origin: config.corsOrigin }));
app.use(express.json({ limit: '256kb' }));

if (config.verbose) {
  app.use((req, _res, next) => {
    // Ingestion is high-frequency; logging every sample drowns the console.
    if (req.path !== '/api/ingest') console.log(`[http] ${req.method} ${req.path}`);
    next();
  });
}

app.get('/api/health', (_req, res) => {
  res.json({
    ok: true,
    service: 'health-companion-backend',
    store: storeStatus(),
    sms: { provider: config.sms.provider, contactConfigured: !!config.sms.emergencyContact },
    weather: { configured: !!config.weather.apiKey, mocked: !!config.weather.mock },
    ml: mlStatus(),
    uptimeSec: Math.round(process.uptime()),
  });
});

app.use('/api/ingest', ingestRoute);
app.use('/api/history', historyRoute);
app.use('/api/alerts', alertsRoute);
app.use('/api/devices', devicesRoute);
app.use('/api/demo', demoRoute);

app.use((_req, res) => res.status(404).json({ ok: false, error: 'not found' }));

// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error('[error]', err);
  res.status(500).json({ ok: false, error: err.message || 'internal error' });
});

const server = http.createServer(app);
initSocket(server);

async function start() {
  await connectStore();

  // Seed one demo wearer so a fresh clone has something to look at.
  await upsertDevice('band-001', {
    wearerName: 'Demo Wearer',
    profile: 'outdoor_worker',
    emergencyContact: config.sms.emergencyContact,
    emergencyContactName: 'Emergency Contact',
    lat: config.weather.lat,
    lon: config.weather.lon,
  });

  server.listen(config.port, () => {
    const s = storeStatus();
    console.log('');
    console.log(`  Personal Health Companion — backend`);
    console.log(`  http://localhost:${config.port}`);
    console.log(`  store: ${s.backend}   sms: ${config.sms.provider}   weather: ${config.weather.apiKey ? 'live' : config.weather.mock ? 'mocked' : 'device-only'}   ml: ${mlStatus().status}`);
    console.log('');
  });
}

const shutdown = (signal) => {
  console.log(`\n[server] ${signal} received, shutting down.`);
  server.close(async () => {
    await closeStore();
    process.exit(0);
  });
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

start().catch((err) => {
  console.error('[server] failed to start:', err);
  process.exit(1);
});
