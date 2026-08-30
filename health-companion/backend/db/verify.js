#!/usr/bin/env node
/**
 * Verify the database wiring end to end against a real PostgreSQL.
 *
 * Run this once after putting DATABASE_URL in .env. It applies the schema,
 * exercises every method the app uses, checks the shapes the frontend depends
 * on, and deletes everything it created.
 *
 *   cd backend && node db/verify.js
 *
 * It uses a throwaway device id, so it cannot disturb real data.
 */

import 'dotenv/config';
import {
  connectStore, storeStatus, closeStore,
  upsertDevice, getDevice, listDevices,
  saveReading, listReadings,
  saveAlert, listAlerts, markAlertSms, acknowledgeAlert,
} from '../src/store.js';
import pg from 'pg';
import config from '../src/config.js';

const DEVICE = `verify-${Date.now()}`;
let pass = 0, fail = 0;

const check = (label, ok, detail = '') => {
  if (ok) { pass++; console.log(`  PASS  ${label}`); }
  else { fail++; console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ''}`); }
};

async function main() {
  if (!config.databaseUrl) {
    console.log('\nDATABASE_URL is empty. Put your Supabase connection string in backend/.env first.\n');
    console.log('Use the SESSION POOLER string, not the direct one:');
    console.log('  Supabase → Project Settings → Database → Connection string → Session pooler');
    console.log('  postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres\n');
    process.exit(1);
  }

  console.log('\nConnecting…');
  await connectStore();

  const status = storeStatus();
  check('connected to PostgreSQL', status.backend === 'postgres',
        `got "${status.backend}" — the connection failed and it fell back to memory`);

  if (status.backend !== 'postgres') {
    console.log('\nThe most common cause is an IPv6-only direct connection URL.');
    console.log('Switch to the Session pooler string and run this again.\n');
    await closeStore();
    process.exit(1);
  }

  // --- devices ---
  const dev = await upsertDevice(DEVICE, {
    wearerName: 'Verify Bot', profile: 'outdoor_worker',
    emergencyContact: '+910000000000', lat: 22.57, lon: 88.36,
  });
  check('upsertDevice creates a device', dev?.deviceId === DEVICE);
  check('device fields come back camelCase', dev?.wearerName === 'Verify Bot' && dev?.profile === 'outdoor_worker');

  const updated = await upsertDevice(DEVICE, { wearerName: 'Verify Bot 2' });
  check('upsertDevice updates an existing device', updated?.wearerName === 'Verify Bot 2');

  check('getDevice reads it back', (await getDevice(DEVICE))?.deviceId === DEVICE);
  check('listDevices includes it', (await listDevices()).some((d) => d.deviceId === DEVICE));

  // --- readings ---
  const now = new Date();
  const reading = await saveReading({
    deviceId: DEVICE, heartRate: 128, spo2: 95, bodyTemp: 37.2,
    ambientTemp: 44, humidity: 68, accelMagnitude: 1.6,
    fallDetected: false, motion: 'active', signalOk: true,
    heatIndex: 58, timestamp: now,
  });
  check('saveReading returns a row', !!reading);
  check('reading exposes _id (the frontend keys on it)', reading?._id !== undefined && reading?._id !== null);
  check('reading values round-trip', Number(reading.heartRate) === 128 && Number(reading.spo2) === 95);
  check('booleans round-trip', reading.fallDetected === false && reading.signalOk === true);

  // a nulls-everywhere sample, which the ESP32 really does send
  const sparse = await saveReading({
    deviceId: DEVICE, heartRate: null, spo2: null, bodyTemp: null,
    ambientTemp: 29, humidity: 55, accelMagnitude: null,
    fallDetected: true, motion: 'unknown', signalOk: false,
    heatIndex: null, timestamp: new Date(Date.now() + 1000),
  });
  check('saveReading accepts null vitals', !!sparse && sparse.heartRate === null);

  const hist = await listReadings(DEVICE, { limit: 10 });
  check('listReadings returns both rows', hist.length === 2);
  check('listReadings is newest-first', hist.length === 2 && new Date(hist[0].timestamp) >= new Date(hist[1].timestamp));

  const windowed = await listReadings(DEVICE, { limit: 10, since: new Date(Date.now() - 60_000) });
  check('listReadings honours "since"', windowed.length === 2);

  // --- alerts ---
  const alert = await saveAlert({
    deviceId: DEVICE, type: 'heat_stress', severity: 'critical',
    message: 'Heat-stress risk: Extreme danger',
    detail: 'Heat index 58°C with heart rate 128 bpm.',
    snapshot: { heartRate: 128, spo2: 95, restingHr: 72 },
    timestamp: now,
  });
  check('saveAlert returns a row', !!alert && alert._id !== undefined);
  check('alert defaults applied (smsSent, acknowledged)', alert.smsSent === false && alert.acknowledged === false);
  check('snapshot round-trips as an object', alert.snapshot?.heartRate === 128);

  await markAlertSms(alert._id, { smsSent: false, smsNote: 'cooldown, 239s remaining' });
  const afterSms = (await listAlerts(DEVICE)).find((a) => String(a._id) === String(alert._id));
  check('markAlertSms records the skip reason', afterSms?.smsNote === 'cooldown, 239s remaining');

  const acked = await acknowledgeAlert(alert._id);
  check('acknowledgeAlert flips the flag', acked?.acknowledged === true);

  check('listAlerts returns it', (await listAlerts(DEVICE)).length === 1);

  // --- foreign key ordering (the trap ingest.js had to avoid) ---
  let fkRejected = false;
  try {
    const probe = new Pool({
      connectionString: config.databaseUrl,
      ssl: config.dbSsl ? { rejectUnauthorized: false } : false,
      max: 1,
    });
    await probe.query(
      `insert into readings (device_id, "timestamp") values ($1, now())`,
      ['device-that-does-not-exist']
    );
    await probe.end();
  } catch (err) {
    fkRejected = /foreign key|violates/i.test(err.message);
  }
  check('readings.device_id foreign key is enforced', fkRejected,
        'a reading for an unknown device was accepted — the constraint is missing');

  // --- cleanup ---
  const cleanup = new Pool({
    connectionString: config.databaseUrl,
    ssl: config.dbSsl ? { rejectUnauthorized: false } : false,
    max: 1,
  });
  await cleanup.query('delete from devices where device_id = $1', [DEVICE]); // cascades
  const { rows } = await cleanup.query(
    'select (select count(*) from readings where device_id=$1)::int as r, (select count(*) from alerts where device_id=$1)::int as a',
    [DEVICE]
  );
  await cleanup.end();
  check('delete cascades to readings and alerts', rows[0].r === 0 && rows[0].a === 0);

  await closeStore();

  console.log(`\n${pass} passed, ${fail} failed\n`);
  if (fail === 0) console.log('Database wiring is good. Start the backend normally.\n');
  process.exit(fail === 0 ? 0 : 1);
}

const { Pool } = pg;

main().catch(async (err) => {
  console.error('\nverification crashed:', err.message);
  if (/ENETUNREACH|ENOTFOUND/i.test(err.message)) {
    console.error('\nThat is the IPv6 problem. Use the Session pooler connection string.\n');
  }
  await closeStore().catch(() => {});
  process.exit(1);
});
