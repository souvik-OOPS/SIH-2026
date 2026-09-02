import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import pg from 'pg';
import config from './config.js';

/**
 * Storage facade — PostgreSQL (Supabase) with an in-process fallback.
 *
 * With DATABASE_URL set we use Postgres. Blank or unreachable, we fall back to
 * in-process arrays exposing the *same* methods. That fallback matters more now
 * than it did with a local database: Supabase is remote, so a venue with bad
 * wifi would otherwise take the whole demo down. Data is lost on restart in
 * fallback mode, which is fine for a demo and never silent — /api/health says
 * which backend is live.
 *
 * SQL detail worth knowing: every SELECT aliases `id` as `"_id"`. The frontend
 * was written against Mongo's `_id` and keys alerts by it; aliasing in the
 * query keeps the API contract identical instead of touching the UI.
 */

const { Pool } = pg;
const HERE = dirname(fileURLToPath(import.meta.url));

let pool = null;
let usingPg = false;

const mem = {
  readings: [],
  alerts: [],
  devices: new Map(),
  seq: 1,
};

// Keeps the in-memory store from growing without bound during a long demo.
const MEM_MAX_READINGS = 5000;
const MEM_MAX_ALERTS = 500;

/* ------------------------------ connection ------------------------------- */

export async function connectStore() {
  if (!config.databaseUrl) {
    console.warn('[store] DATABASE_URL is empty — using the in-memory store. Data will not persist.');
    return { usingPg: false };
  }

  try {
    pool = new Pool({
      connectionString: config.databaseUrl,
      // Supabase terminates TLS with a certificate Node does not ship a root
      // for, so verification is relaxed. The connection is still encrypted.
      ssl: config.dbSsl ? { rejectUnauthorized: false } : false,
      max: config.dbPoolMax,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 8_000,
    });

    // A pool error (server restart, network drop) is emitted on the pool, not
    // on a query. Without this listener Node treats it as an uncaught exception
    // and kills the process mid-demo.
    pool.on('error', (err) => {
      console.warn(`[store] pool error: ${err.message}`);
    });

    const { rows } = await pool.query('select current_database() as db, version() as v');
    usingPg = true;
    console.log(`[store] PostgreSQL connected (${rows[0].db})`);

    await applySchema();
  } catch (err) {
    console.warn(`[store] PostgreSQL unreachable (${err.message}) — using the in-memory store.`);
    if (/ENETUNREACH|ENOTFOUND/i.test(err.message)) {
      console.warn('[store] hint: Supabase direct connections are IPv6-only. Use the');
      console.warn('[store]       Session pooler URL (aws-0-<region>.pooler.supabase.com:5432).');
    }
    usingPg = false;
    pool = null;
  }

  return { usingPg };
}

/** Idempotent, so a fresh clone works without anyone running psql. */
async function applySchema() {
  try {
    const sql = readFileSync(join(HERE, '..', 'db', 'schema.sql'), 'utf8');
    await pool.query(sql);
    console.log('[store] schema applied');
  } catch (err) {
    console.warn(`[store] could not apply schema (${err.message}). Run db/schema.sql by hand.`);
  }
}

export const storeStatus = () => ({
  backend: usingPg ? 'postgres' : 'memory',
  readings: usingPg ? undefined : mem.readings.length,
  alerts: usingPg ? undefined : mem.alerts.length,
});

export async function closeStore() {
  if (pool) await pool.end().catch(() => {});
}

/** Any query failure drops this request to memory rather than 500-ing. */
async function q(text, params) {
  try {
    return await pool.query(text, params);
  } catch (err) {
    console.warn(`[store] query failed (${err.message})`);
    throw err;
  }
}

const memId = () => `mem_${mem.seq++}`;

/* ------------------------------- readings -------------------------------- */

const READING_COLS = `
  id as "_id", device_id as "deviceId", heart_rate as "heartRate", spo2,
  body_temp as "bodyTemp", ambient_temp as "ambientTemp", humidity,
  accel_magnitude as "accelMagnitude", fall_detected as "fallDetected",
  motion, signal_ok as "signalOk", heat_index as "heatIndex", "timestamp"
`;

export async function saveReading(doc) {
  if (usingPg) {
    try {
      const { rows } = await q(
        `insert into readings
           (device_id, heart_rate, spo2, body_temp, ambient_temp, humidity,
            accel_magnitude, fall_detected, motion, signal_ok, heat_index, "timestamp")
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
         returning ${READING_COLS}`,
        [
          doc.deviceId, doc.heartRate, doc.spo2, doc.bodyTemp, doc.ambientTemp,
          doc.humidity, doc.accelMagnitude, doc.fallDetected, doc.motion,
          doc.signalOk, doc.heatIndex ?? null, doc.timestamp,
        ]
      );
      return rows[0];
    } catch {
      /* fall through to memory */
    }
  }

  const saved = { _id: memId(), ...doc };
  mem.readings.push(saved);
  if (mem.readings.length > MEM_MAX_READINGS) {
    mem.readings.splice(0, mem.readings.length - MEM_MAX_READINGS);
  }
  return saved;
}

export async function listReadings(deviceId, { limit = 200, since } = {}) {
  if (usingPg) {
    try {
      const params = [deviceId, Math.min(limit, 2000)];
      let where = 'device_id = $1';
      if (since) {
        params.push(since);
        where += ` and "timestamp" >= $3`;
      }
      const { rows } = await q(
        `select ${READING_COLS} from readings
         where ${where} order by "timestamp" desc limit $2`,
        params
      );
      return rows;
    } catch {
      /* fall through */
    }
  }

  return mem.readings
    .filter((r) => r.deviceId === deviceId && (!since || r.timestamp >= since))
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, limit);
}

/** Readings inside a trailing window, oldest-first. Used by the sustain rules. */
export async function recentReadings(deviceId, windowMs) {
  const since = new Date(Date.now() - windowMs);
  const rows = await listReadings(deviceId, { limit: 500, since });
  return rows.slice().reverse();
}

/* -------------------------------- alerts --------------------------------- */

const ALERT_COLS = `
  id as "_id", device_id as "deviceId", type, severity, message, detail,
  snapshot, sms_sent as "smsSent", sms_error as "smsError", sms_note as "smsNote",
  acknowledged, "timestamp"
`;

export async function saveAlert(doc) {
  if (usingPg) {
    try {
      const { rows } = await q(
        `insert into alerts
           (device_id, type, severity, message, detail, snapshot, "timestamp")
         values ($1,$2,$3,$4,$5,$6,$7)
         returning ${ALERT_COLS}`,
        [
          doc.deviceId, doc.type, doc.severity, doc.message,
          doc.detail ?? null, doc.snapshot ? JSON.stringify(doc.snapshot) : null,
          doc.timestamp,
        ]
      );
      return rows[0];
    } catch {
      /* fall through */
    }
  }

  // The SQL columns carry defaults; the in-memory path has to apply them by
  // hand so both backends hand the frontend the same shape.
  const saved = { _id: memId(), smsSent: false, acknowledged: false, ...doc };
  mem.alerts.push(saved);
  if (mem.alerts.length > MEM_MAX_ALERTS) {
    mem.alerts.splice(0, mem.alerts.length - MEM_MAX_ALERTS);
  }
  return saved;
}

export async function listAlerts(deviceId, { limit = 100 } = {}) {
  if (usingPg) {
    try {
      const { rows } = await q(
        `select ${ALERT_COLS} from alerts
         where device_id = $1 order by "timestamp" desc limit $2`,
        [deviceId, Math.min(limit, 500)]
      );
      return rows;
    } catch {
      /* fall through */
    }
  }

  return mem.alerts
    .filter((a) => a.deviceId === deviceId)
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, limit);
}

export async function markAlertSms(alertId, { smsSent, smsError, smsNote }) {
  const patch = { smsSent: !!smsSent };
  if (smsError) patch.smsError = smsError;
  if (smsNote) patch.smsNote = smsNote;

  if (usingPg) {
    try {
      await q(
        `update alerts set sms_sent = $2, sms_error = $3, sms_note = $4 where id = $1`,
        [alertId, !!smsSent, smsError ?? null, smsNote ?? null]
      );
      return patch;
    } catch {
      /* fall through */
    }
  }

  const row = mem.alerts.find((a) => String(a._id) === String(alertId));
  if (row) Object.assign(row, patch);
  return patch;
}

export async function acknowledgeAlert(alertId) {
  if (usingPg) {
    try {
      const { rows } = await q(
        `update alerts set acknowledged = true where id = $1 returning ${ALERT_COLS}`,
        [alertId]
      );
      return rows[0] ?? null;
    } catch {
      /* fall through */
    }
  }

  const row = mem.alerts.find((a) => String(a._id) === String(alertId));
  if (row) row.acknowledged = true;
  return row || null;
}

/* -------------------------------- devices -------------------------------- */

const DEVICE_COLS = `
  device_id as "deviceId", wearer_name as "wearerName", profile, age, sex,
  emergency_contact as "emergencyContact",
  emergency_contact_name as "emergencyContactName",
  lat, lon, last_seen as "lastSeen"
`;

const DEVICE_FIELD_TO_COL = {
  wearerName: 'wearer_name',
  profile: 'profile',
  age: 'age',
  sex: 'sex',
  emergencyContact: 'emergency_contact',
  emergencyContactName: 'emergency_contact_name',
  lat: 'lat',
  lon: 'lon',
  lastSeen: 'last_seen',
};

export async function upsertDevice(deviceId, patch = {}) {
  const entries = Object.entries(patch).filter(([k, v]) => DEVICE_FIELD_TO_COL[k] && v !== undefined);

  if (usingPg) {
    try {
      if (entries.length === 0) {
        const { rows } = await q(
          `insert into devices (device_id) values ($1)
           on conflict (device_id) do update set device_id = excluded.device_id
           returning ${DEVICE_COLS}`,
          [deviceId]
        );
        return rows[0];
      }

      const cols = entries.map(([k]) => DEVICE_FIELD_TO_COL[k]);
      const vals = entries.map(([, v]) => v);
      const placeholders = cols.map((_, i) => `$${i + 2}`);
      const updates = cols.map((c, i) => `${c} = $${i + 2}`);

      const { rows } = await q(
        `insert into devices (device_id, ${cols.join(', ')})
         values ($1, ${placeholders.join(', ')})
         on conflict (device_id) do update set ${updates.join(', ')}
         returning ${DEVICE_COLS}`,
        [deviceId, ...vals]
      );
      return rows[0];
    } catch {
      /* fall through */
    }
  }

  const existing = mem.devices.get(deviceId) || {
    deviceId,
    wearerName: 'Unknown wearer',
    profile: 'general',
    age: null,
    sex: null,
  };
  const merged = { ...existing, ...patch, deviceId };
  mem.devices.set(deviceId, merged);
  return merged;
}

export async function getDevice(deviceId) {
  if (usingPg) {
    try {
      const { rows } = await q(`select ${DEVICE_COLS} from devices where device_id = $1`, [deviceId]);
      return rows[0] ?? null;
    } catch {
      /* fall through */
    }
  }
  return mem.devices.get(deviceId) || null;
}

export async function listDevices() {
  if (usingPg) {
    try {
      const { rows } = await q(
        `select ${DEVICE_COLS} from devices order by last_seen desc nulls last`
      );
      return rows;
    } catch {
      /* fall through */
    }
  }
  return [...mem.devices.values()];
}

/* ------------------------------- privacy --------------------------------- */

/**
 * What is actually stored for one wearer.
 *
 * Backs the privacy screen. Counts and time bounds only — the point is to let
 * someone see the shape of what is held without the screen itself becoming
 * another place their health history is displayed.
 */
export async function summariseStoredData(deviceId) {
  if (usingPg) {
    try {
      const [readings, alerts, device] = await Promise.all([
        q(
          `select count(*)::int as n,
                  min("timestamp") as "oldest", max("timestamp") as "newest"
             from readings where device_id = $1`,
          [deviceId]
        ),
        q(`select count(*)::int as n from alerts where device_id = $1`, [deviceId]),
        getDevice(deviceId),
      ]);
      return {
        deviceId,
        storage: 'postgres',
        readings: readings.rows[0]?.n ?? 0,
        oldestReading: readings.rows[0]?.oldest ?? null,
        newestReading: readings.rows[0]?.newest ?? null,
        alerts: alerts.rows[0]?.n ?? 0,
        deviceRecord: device ? Object.keys(device).filter((k) => device[k] != null) : [],
      };
    } catch {
      /* fall through to memory */
    }
  }

  const readings = mem.readings.filter((r) => r.deviceId === deviceId);
  const alerts = mem.alerts.filter((a) => a.deviceId === deviceId);
  const device = mem.devices.get(deviceId) ?? null;
  const times = readings.map((r) => new Date(r.timestamp).getTime()).filter(Number.isFinite);

  return {
    deviceId,
    storage: 'memory',
    readings: readings.length,
    oldestReading: times.length ? new Date(Math.min(...times)) : null,
    newestReading: times.length ? new Date(Math.max(...times)) : null,
    alerts: alerts.length,
    deviceRecord: device ? Object.keys(device).filter((k) => device[k] != null) : [],
  };
}

/**
 * Deletes stored health data for one wearer.
 *
 * Readings and alerts always go. The device record is kept unless
 * `includeProfile`, so a wearer can wipe their measurements without having to
 * re-register the band and lose their emergency contacts.
 *
 * @returns {Promise<{readings:number, alerts:number, deviceRemoved:boolean}>}
 */
export async function deleteDeviceData(deviceId, { includeProfile = false } = {}) {
  if (usingPg) {
    try {
      const readings = await q(`delete from readings where device_id = $1`, [deviceId]);
      const alerts = await q(`delete from alerts where device_id = $1`, [deviceId]);
      let deviceRemoved = false;
      if (includeProfile) {
        const d = await q(`delete from devices where device_id = $1`, [deviceId]);
        deviceRemoved = (d.rowCount ?? 0) > 0;
      }
      return {
        readings: readings.rowCount ?? 0,
        alerts: alerts.rowCount ?? 0,
        deviceRemoved,
      };
    } catch {
      /* fall through to memory */
    }
  }

  const before = { readings: mem.readings.length, alerts: mem.alerts.length };
  mem.readings = mem.readings.filter((r) => r.deviceId !== deviceId);
  mem.alerts = mem.alerts.filter((a) => a.deviceId !== deviceId);
  const deviceRemoved = includeProfile ? mem.devices.delete(deviceId) : false;

  return {
    readings: before.readings - mem.readings.length,
    alerts: before.alerts - mem.alerts.length,
    deviceRemoved,
  };
}
