#!/usr/bin/env node
/**
 * Sensor simulator — stands in for the ESP32 until the hardware arrives, and
 * drives the demo afterwards (you cannot give a judge hypoxia on stage).
 *
 * Usage:
 *   npm run simulate                          # normal vitals, forever
 *   npm run simulate -- --scenario=heatwave
 *   npm run simulate:demo                     # the scripted demo sequence
 *
 * Flags:
 *   --scenario=normal|exertion|hypoxia|fall|heatwave|pollution|demo
 *   --device=band-001
 *   --interval=1000        ms between samples
 *   --url=http://localhost:4000
 *   --key=<DEVICE_API_KEY> if the backend requires one
 */

import 'dotenv/config';

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, '').split('=');
    return [k, v === undefined ? true : v];
  })
);

const BASE = args.url || process.env.SIM_URL || `http://localhost:${process.env.PORT || 4000}`;
const DEVICE = args.device || 'band-001';
const INTERVAL = Number(args.interval) || 1000;
const API_KEY = args.key || process.env.DEVICE_API_KEY || '';
const SCENARIO = args.scenario || 'normal';

/* ------------------------------ vitals model ------------------------------ */

const jitter = (amp) => (Math.random() - 0.5) * 2 * amp;
const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));

/** Drift a value toward a target instead of snapping — real vitals have inertia. */
const drift = (current, target, rate, noise) =>
  current + (target - current) * rate + jitter(noise);

const vitals = {
  heartRate: 72,
  spo2: 98,
  bodyTemp: 36.8,
  ambientTemp: 29,
  humidity: 55,
  accelMagnitude: 1.0,
};

/**
 * Each scenario is a target state plus how hard the body is working.
 * `fall` is a one-shot event, handled separately.
 */
const SCENARIOS = {
  normal: { heartRate: 74, spo2: 98, ambientTemp: 29, humidity: 55, motion: 'rest' },
  exertion: { heartRate: 138, spo2: 96, ambientTemp: 30, humidity: 58, motion: 'active' },
  hypoxia: { heartRate: 104, spo2: 86, ambientTemp: 29, humidity: 55, motion: 'light' },
  heatwave: { heartRate: 128, spo2: 95, ambientTemp: 44, humidity: 63, motion: 'active' },
  pollution: { heartRate: 96, spo2: 93, ambientTemp: 31, humidity: 60, motion: 'light' },
};

const MOTION_ACCEL = { rest: 1.0, light: 1.15, active: 1.6 };

function step(target) {
  vitals.heartRate = clamp(drift(vitals.heartRate, target.heartRate, 0.12, 1.5), 40, 200);
  vitals.spo2 = clamp(drift(vitals.spo2, target.spo2, 0.15, 0.4), 70, 100);
  vitals.ambientTemp = clamp(drift(vitals.ambientTemp, target.ambientTemp, 0.08, 0.2), -10, 60);
  vitals.humidity = clamp(drift(vitals.humidity, target.humidity, 0.08, 0.8), 5, 100);
  vitals.bodyTemp = clamp(drift(vitals.bodyTemp, target.ambientTemp > 40 ? 37.6 : 36.8, 0.05, 0.05), 35, 42);
  vitals.accelMagnitude = clamp(
    drift(vitals.accelMagnitude, MOTION_ACCEL[target.motion] ?? 1.0, 0.3, 0.05),
    0.5,
    3
  );

  return {
    deviceId: DEVICE,
    heartRate: Math.round(vitals.heartRate),
    spo2: Math.round(vitals.spo2),
    bodyTemp: Math.round(vitals.bodyTemp * 10) / 10,
    ambientTemp: Math.round(vitals.ambientTemp * 10) / 10,
    humidity: Math.round(vitals.humidity),
    accelMagnitude: Math.round(vitals.accelMagnitude * 100) / 100,
    motion: target.motion,
    fallDetected: false,
    // Occasionally flag a bad PPG sample, the way real motion artefact looks.
    signalOk: Math.random() > 0.03,
    timestamp: new Date().toISOString(),
  };
}

function fallSample() {
  return {
    deviceId: DEVICE,
    heartRate: Math.round(vitals.heartRate),
    spo2: Math.round(vitals.spo2),
    ambientTemp: Math.round(vitals.ambientTemp * 10) / 10,
    humidity: Math.round(vitals.humidity),
    accelMagnitude: 3.8,
    motion: 'active',
    fallDetected: true,
    signalOk: true,
    timestamp: new Date().toISOString(),
  };
}

/* ------------------------------- transport -------------------------------- */

async function post(sample) {
  try {
    const res = await fetch(`${BASE}/api/ingest`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(API_KEY ? { 'x-api-key': API_KEY } : {}),
      },
      body: JSON.stringify(sample),
    });
    const json = await res.json().catch(() => ({}));

    if (!res.ok) {
      console.error(`  ! ingest failed: HTTP ${res.status} ${json.error || ''}`);
      return;
    }

    const d = json.reading?.derived || {};
    const line =
      `  HR ${String(sample.heartRate).padStart(3)}  ` +
      `SpO2 ${String(sample.spo2).padStart(3)}%  ` +
      `amb ${String(sample.ambientTemp).padStart(4)}C/${String(sample.humidity).padStart(2)}%  ` +
      `HI ${String(d.heatIndex ?? '-').padStart(4)}C  ` +
      `rest ${String(d.restingHr ?? '-').padStart(3)}`;

    if (json.alerts?.length) {
      const tags = json.alerts.map((a) => `${a.severity.toUpperCase()}:${a.type}`).join(' ');
      console.log(`${line}   <<< ${tags}`);
    } else {
      console.log(line);
    }
  } catch (err) {
    console.error(`  ! cannot reach ${BASE} — is the backend running? (${err.message})`);
  }
}

async function setEnv(preset) {
  try {
    await fetch(`${BASE}/api/demo/env`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ preset }),
    });
  } catch {
    /* the demo route is optional */
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* -------------------------------- runners --------------------------------- */

async function runSteady(name) {
  const target = SCENARIOS[name];
  if (!target) {
    console.error(`Unknown scenario "${name}". Options: ${Object.keys(SCENARIOS).join(', ')}, fall, demo`);
    process.exit(1);
  }
  console.log(`\n  simulator -> ${BASE}   device=${DEVICE}   scenario=${name}   every ${INTERVAL}ms`);
  console.log('  Ctrl+C to stop\n');

  for (;;) {
    await post(step(target));
    await sleep(INTERVAL);
  }
}

async function runFall() {
  console.log(`\n  simulator -> ${BASE}   device=${DEVICE}   scenario=fall\n`);
  for (let i = 0; i < 5; i++) {
    await post(step(SCENARIOS.normal));
    await sleep(INTERVAL);
  }
  console.log('  --- fall event ---');
  await post(fallSample());
  // After a fall the wearer is motionless — that stillness is the confirmation.
  for (let i = 0; i < 8; i++) {
    await post({ ...step({ ...SCENARIOS.normal, heartRate: 96 }), motion: 'rest', accelMagnitude: 1.0 });
    await sleep(INTERVAL);
  }
  console.log('\n  done.\n');
}

/**
 * The scripted demo. Matches the demo script in the README, in order, so the
 * video can be recorded in one take.
 */
async function runDemo() {
  const phases = [
    { label: '1/5  Baseline — wearer at rest, vitals normal', scenario: 'normal', seconds: 20, env: 'normal' },
    { label: '2/5  Exertion — heart rate climbs past threshold', scenario: 'exertion', seconds: 52 },
    { label: '3/5  Heatwave — ambient 44C, heat-stress rule cross-references environment', scenario: 'heatwave', seconds: 35, env: 'heatwave' },
    { label: '4/5  Desaturation — SpO2 falls, CRITICAL alert + SMS', scenario: 'hypoxia', seconds: 25 },
    { label: '5/5  Fall detected — CRITICAL alert + SMS', scenario: 'fall', seconds: 12 },
  ];

  console.log(`\n  DEMO SEQUENCE -> ${BASE}   device=${DEVICE}`);
  console.log('  Open the dashboard at http://localhost:3000 before starting.\n');
  await sleep(1500);

  for (const phase of phases) {
    console.log(`\n${'-'.repeat(72)}\n  ${phase.label}\n${'-'.repeat(72)}`);
    if (phase.env) await setEnv(phase.env);

    if (phase.scenario === 'fall') {
      await post(fallSample());
      for (let i = 0; i < phase.seconds; i++) {
        await post({ ...step({ ...SCENARIOS.normal, heartRate: 98 }), motion: 'rest', accelMagnitude: 1.0 });
        await sleep(INTERVAL);
      }
      continue;
    }

    const target = SCENARIOS[phase.scenario];
    for (let i = 0; i < phase.seconds; i++) {
      await post(step(target));
      await sleep(INTERVAL);
    }
  }

  await setEnv('normal');
  console.log('\n  Demo complete. Check the alert log in the dashboard.\n');
}

/* --------------------------------- entry ---------------------------------- */

process.on('SIGINT', () => {
  console.log('\n  simulator stopped.\n');
  process.exit(0);
});

if (SCENARIO === 'demo') runDemo();
else if (SCENARIO === 'fall') runFall();
else runSteady(SCENARIO);
