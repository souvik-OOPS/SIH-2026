import config from '../config.js';

/**
 * Multi-stage fall detection from accelerometer telemetry.
 *
 * A single acceleration threshold cannot tell a fall from setting the phone
 * down hard: both produce one large spike. What separates them is the shape of
 * what follows, so this walks a small state machine instead:
 *
 *   free fall (optional)  ->  impact  ->  orientation change  ->  stillness
 *
 * Free fall and orientation change are *corroborating* stages, not required
 * ones. A fall from sitting barely registers free fall, and a device worn on
 * the wrist can land oriented much as it started. Requiring every stage would
 * miss real falls; requiring only impact would fire on every knock. So impact
 * plus sustained stillness is the minimum, and each extra stage that fires
 * raises the reported confidence rather than gating the verdict.
 *
 * Orientation needs the gravity vector, which a scalar magnitude cannot carry.
 * When only magnitude is available the detector says so in `stages` and
 * reports lower confidence, rather than pretending it checked.
 */

const state = new Map(); // deviceId -> detector state

export function resetFallState(deviceId) {
  if (deviceId) state.delete(deviceId);
  else state.clear();
}

function detectorState(deviceId) {
  if (!state.has(deviceId)) {
    state.set(deviceId, {
      phase: 'idle', // idle | impacted | confirming
      freeFallAt: null,
      impactAt: null,
      impactG: null,
      /** Gravity direction sampled before the impact, for the orientation test. */
      referenceVector: null,
      orientationDeg: null,
      stillSince: null,
      lastVector: null,
      recent: [], // rolling window of {t, g} for the reference and stillness tests
    });
  }
  return state.get(deviceId);
}

export function getFallState(deviceId) {
  const s = state.get(deviceId);
  if (!s) return { phase: 'idle' };
  return {
    phase: s.phase,
    impactAt: s.impactAt,
    impactG: s.impactG,
    orientationDeg: s.orientationDeg,
  };
}

/** Angle between two acceleration vectors, in degrees. */
export function angleBetween(a, b) {
  if (!a || !b) return null;
  const dot = a.x * b.x + a.y * b.y + a.z * b.z;
  const ma = Math.sqrt(a.x ** 2 + a.y ** 2 + a.z ** 2);
  const mb = Math.sqrt(b.x ** 2 + b.y ** 2 + b.z ** 2);
  if (ma === 0 || mb === 0) return null;
  const cos = Math.min(1, Math.max(-1, dot / (ma * mb)));
  return (Math.acos(cos) * 180) / Math.PI;
}

/**
 * Feeds one reading to the detector.
 *
 * @returns {{fall: boolean, confidence: number, stages: object, reason: string|null}}
 */
export function evaluateFall(reading, { now = Date.parse(reading.timestamp) || Date.now() } = {}) {
  const cfg = config.fall;
  const s = detectorState(reading.deviceId);
  const g = reading.accelMagnitude;
  const vec = reading.accel ?? null;

  const idle = {
    fall: false,
    confidence: 0,
    stages: { freeFall: false, impact: false, orientation: null, stillness: false },
    reason: null,
  };

  // A device that reports its own verdict is trusted: it sampled at ~50 Hz,
  // which this 1 Hz stream cannot reconstruct. The stages below are for
  // telemetry that arrives without a verdict.
  if (reading.fallDetected === true) {
    s.phase = 'idle';
    return {
      fall: true,
      confidence: 1,
      stages: { freeFall: null, impact: true, orientation: null, stillness: null },
      reason: 'Reported by the wearable device, which samples motion far faster than this stream.',
      source: 'device',
    };
  }

  if (g == null) return idle;

  // Rolling window, used to pick a pre-impact reference and to test stillness.
  s.recent.push({ t: now, g, vec });
  const windowStart = now - cfg.windowMs;
  while (s.recent.length && s.recent[0].t < windowStart) s.recent.shift();

  if (s.phase === 'idle') {
    if (g <= cfg.freeFallG) {
      s.freeFallAt = now;
      // Gravity direction just before the drop is the cleanest reference.
      const before = s.recent.filter((r) => r.t < now && r.vec).slice(-3)[0];
      if (before) s.referenceVector = before.vec;
    }

    if (g >= cfg.impactG) {
      s.phase = 'impacted';
      s.impactAt = now;
      s.impactG = g;
      s.stillSince = null;
      s.orientationDeg = null;
      if (!s.referenceVector) {
        const before = s.recent.filter((r) => r.t < now - 500 && r.vec).slice(-1)[0];
        if (before) s.referenceVector = before.vec;
      }
      // Free fall counts only if it immediately preceded the impact.
      if (s.freeFallAt && now - s.freeFallAt > cfg.freeFallWindowMs) s.freeFallAt = null;
    }
    return idle;
  }

  // --- after an impact: look for orientation change, then sustained stillness
  const sinceImpact = now - s.impactAt;

  if (sinceImpact > cfg.verificationMs) {
    // The window closed without the stillness a real fall produces. Most
    // likely a knock, a dropped device, or the wearer carried on moving.
    s.phase = 'idle';
    s.freeFallAt = null;
    s.referenceVector = null;
    return idle;
  }

  if (vec && s.referenceVector && s.orientationDeg == null) {
    const deg = angleBetween(s.referenceVector, vec);
    if (deg != null && deg >= cfg.orientationDeg) s.orientationDeg = deg;
  }

  const still = Math.abs(g - 1) <= cfg.stillnessBandG;
  if (still) {
    if (s.stillSince == null) s.stillSince = now;
  } else {
    s.stillSince = null;
  }

  const stillFor = s.stillSince == null ? 0 : now - s.stillSince;
  if (stillFor < cfg.stillnessMs) return idle;

  // --- all required stages met
  const stages = {
    freeFall: Boolean(s.freeFallAt),
    impact: true,
    // null means "could not be checked", which is not the same as "did not happen".
    orientation: vec || s.referenceVector ? s.orientationDeg != null : null,
    stillness: true,
  };

  let confidence = 0.6; // impact + stillness alone
  if (stages.freeFall) confidence += 0.2;
  if (stages.orientation === true) confidence += 0.2;
  confidence = Math.min(1, Number(confidence.toFixed(2)));

  const parts = [`impact of ${s.impactG.toFixed(1)} g`];
  if (stages.freeFall) parts.unshift('free fall');
  // Plain 'deg' rather than the degree sign: this text is appended to the
  // emergency SMS, and one non-GSM-7 character forces the whole message into
  // UCS-2, cutting a segment from 160 characters to 70.
  if (stages.orientation === true) parts.push(`orientation changed ${Math.round(s.orientationDeg)} deg`);
  parts.push(`no movement for ${Math.round(stillFor / 1000)}s`);

  const reason = `${parts.join(', then ')}.`;

  s.phase = 'idle';
  s.freeFallAt = null;
  s.referenceVector = null;
  s.stillSince = null;

  return { fall: true, confidence, stages, reason, source: 'telemetry' };
}
