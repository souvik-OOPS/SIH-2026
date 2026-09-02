import config from '../config.js';
import { assessHeatStress, assessAirQuality, heatIndexC } from './heatStress.js';
import { scoreReading, resetMlBuffer } from './mlDetector.js';
import { evaluateFall, resetFallState } from './fallDetection.js';
import { openCheckIn, checkInStatus, resetNonResponse } from './nonResponse.js';

/**
 * Rule-based anomaly detection (v1).
 *
 * Deliberately simple and inspectable — every alert carries the numbers that
 * tripped it, so the dashboard can show *why*, not just *that*. The seam for
 * swapping in a learned model later is evaluateReading(): it takes a reading
 * plus context and returns alerts, nothing else.
 *
 * Two things here go past plain thresholds, and both are cheap:
 *   - a personalised resting-HR baseline learned from the wearer's own rest data
 *   - heat stress judged on apparent temperature (heat index) AND the body's
 *     response to it, not on dry-bulb temperature alone
 */

/* ------------------------- per-device runtime state ------------------------ */

const state = new Map(); // deviceId -> { conditionSince, lastAlertAt, restingHr, samples }

function deviceState(deviceId) {
  if (!state.has(deviceId)) {
    state.set(deviceId, {
      conditionSince: new Map(), // ruleKey -> epoch ms the condition first held
      lastAlertAt: new Map(), // alertType -> epoch ms
      restingHr: null, // EWMA of at-rest heart rate
      samples: 0,
    });
  }
  return state.get(deviceId);
}

export function resetDeviceState(deviceId) {
  if (deviceId) state.delete(deviceId);
  else state.clear();
  resetMlBuffer(deviceId);
  resetFallState(deviceId);
  resetNonResponse(deviceId);
}

/**
 * How far past the learned threshold before the model is allowed to raise an
 * alert on its own. Deliberately conservative: the model is trained on resting
 * ICU physiology and has seen almost no exercise, so mild elevation from
 * walking scores high without being an emergency. The score is always shown;
 * only a large, sustained excursion pages anyone.
 */
const ML_ALERT_RATIO = 1.6;

export function getBaseline(deviceId) {
  const s = state.get(deviceId);
  if (!s) return { restingHr: null, samples: 0, ready: false, minSamples: BASELINE_MIN_SAMPLES };
  return {
    restingHr: s.restingHr,
    samples: s.samples,
    ready: baselineReady(s),
    minSamples: BASELINE_MIN_SAMPLES,
  };
}

/**
 * Track how long a condition has held continuously.
 * @returns {number} milliseconds the condition has been true, 0 if it just broke
 */
function sustainedFor(s, ruleKey, isTrue, now) {
  if (!isTrue) {
    s.conditionSince.delete(ruleKey);
    return 0;
  }
  if (!s.conditionSince.has(ruleKey)) {
    s.conditionSince.set(ruleKey, now);
    return 0;
  }
  return now - s.conditionSince.get(ruleKey);
}

function cooledDown(s, type, now) {
  const prev = s.lastAlertAt.get(type);
  return !prev || now - prev >= config.alerts.cooldownMs;
}

/* ------------------------------- thresholds ------------------------------- */

/**
 * Per-profile limits. The problem statement calls out elderly citizens, outdoor
 * workers and people with chronic conditions as the vulnerable groups, so they
 * get tighter bounds rather than one-size-fits-all numbers.
 */
const PROFILE_THRESHOLDS = {
  general: { hrHigh: 120, hrLow: 50, spo2Low: 92, spo2Critical: 88 },
  elderly: { hrHigh: 110, hrLow: 45, spo2Low: 93, spo2Critical: 89 },
  outdoor_worker: { hrHigh: 125, hrLow: 45, spo2Low: 92, spo2Critical: 88 },
  chronic_condition: { hrHigh: 110, hrLow: 50, spo2Low: 94, spo2Critical: 90 },
};

/**
 * Age-adjusted heart-rate ceiling.
 *
 * Uses Tanaka et al. (2001), HRmax = 208 - 0.7 x age, rather than the more
 * familiar 220 - age: the Fox formula systematically underestimates maximum
 * heart rate in older adults, which is exactly the group this project targets.
 *
 * 70% of HRmax is the ceiling for a *sustained* rate in daily activity, not a
 * training zone. It lands at ~136 bpm at 20 and ~109 bpm at 75, then clamps so
 * an implausible age cannot produce an unsafe bound.
 */
function ageAdjustedHrHigh(age) {
  const hrMax = 208 - 0.7 * age;
  const ceiling = Math.round(0.7 * hrMax);
  return Math.min(140, Math.max(95, ceiling));
}

export const AGE_MIN = 1;
export const AGE_MAX = 120;

export const isUsableAge = (age) =>
  typeof age === 'number' && Number.isFinite(age) && age >= AGE_MIN && age <= AGE_MAX;

/**
 * Limits in force for a wearer.
 *
 * Age may only *tighten* the heart-rate ceiling, never raise it. A sustained
 * 120 bpm at rest is worth flagging at any age, and letting age relax the bound
 * would leave the young the least protected by the very rule meant to
 * personalise their care.
 *
 * @param {string} profile  vulnerability category
 * @param {number} [age]    years; ignored when absent or implausible
 */
export function thresholdsFor(profile, age) {
  const base = PROFILE_THRESHOLDS[profile] || PROFILE_THRESHOLDS.general;
  if (!isUsableAge(age)) return { ...base, hrHighSource: 'profile' };

  const byAge = ageAdjustedHrHigh(age);
  if (byAge >= base.hrHigh) return { ...base, hrHighSource: 'profile' };
  return { ...base, hrHigh: byAge, hrHighSource: 'age' };
}

/* --------------------------- baseline learning ---------------------------- */

const REST_HR_ALPHA = 0.05; // slow EWMA — a baseline should not chase one bad sample

/**
 * Samples of rest needed before the learned baseline is trusted for alerting.
 * Below this the EWMA is still dominated by whatever the first reading was.
 */
const BASELINE_MIN_SAMPLES = 60;

/**
 * How far above the wearer's own resting rate counts as a real excursion.
 * Chosen wide: normal daily variation, a warm room, or standing up all move
 * resting HR by 10-20 bpm without meaning anything.
 */
const RELATIVE_HR_DELTA = 30;

/** One definition of "at rest", shared by baseline learning and the rules. */
function isAtRest(reading) {
  return (
    reading.motion === 'rest' ||
    (reading.accelMagnitude != null && Math.abs(reading.accelMagnitude - 1) < 0.08)
  );
}

const baselineReady = (s) => s.restingHr != null && s.samples >= BASELINE_MIN_SAMPLES;

function updateBaseline(s, reading) {
  s.samples += 1;
  const atRest = isAtRest(reading);
  if (!atRest || reading.heartRate == null || reading.signalOk === false) return;
  // Ignore implausible resting values so a PPG glitch can't poison the baseline.
  if (reading.heartRate < 35 || reading.heartRate > 110) return;

  // Do not learn from an excursion the rules are about to flag. Without this
  // the EWMA chases the very elevation it exists to detect: at alpha 0.05 a
  // jump from 55 to 95 bpm drags the baseline to 86 within one 30s sustain
  // window, shrinking a 40 bpm excursion to 9 and silencing the rule.
  // Freezing is also the clinically correct call — a resting rate that stays
  // high is a signal worth continuing to report, not one to normalise away.
  if (baselineReady(s) && reading.heartRate > s.restingHr + RELATIVE_HR_DELTA) return;

  s.restingHr =
    s.restingHr == null
      ? reading.heartRate
      : s.restingHr * (1 - REST_HR_ALPHA) + reading.heartRate * REST_HR_ALPHA;
}

/* -------------------------------- the rules ------------------------------- */

/**
 * @param {object} reading  the sample just ingested
 * @param {object} ctx      { device, ambient }  ambient may be null (offline)
 * @returns {{ alerts: object[], derived: object }}
 */
export function evaluateReading(reading, { device = null, ambient = null } = {}) {
  const now = Date.parse(reading.timestamp) || Date.now();
  const s = deviceState(reading.deviceId);
  updateBaseline(s, reading);

  const t = thresholdsFor(device?.profile, device?.age);
  const alerts = [];
  const sustainMs = config.alerts.sustainWindowMs;

  const push = (type, severity, message, detail) => {
    if (!cooledDown(s, type, now)) return;
    s.lastAlertAt.set(type, now);
    alerts.push({
      deviceId: reading.deviceId,
      type,
      severity,
      message,
      detail,
      snapshot: {
        heartRate: reading.heartRate ?? null,
        spo2: reading.spo2 ?? null,
        ambientTemp: reading.ambientTemp ?? null,
        humidity: reading.humidity ?? null,
        accelMagnitude: reading.accelMagnitude ?? null,
        restingHr: s.restingHr == null ? null : Math.round(s.restingHr),
      },
      timestamp: new Date(now),
    });
  };

  // --- Fall: an event, so no sustain window. The detector walks impact ->
  //     orientation -> stillness rather than trusting one spike, and the same
  //     code runs for replay fixtures, the simulator and live hardware. ---
  const fall = evaluateFall(reading, { now });
  if (fall.fall) {
    push(
      'fall',
      'critical',
      'Possible fall detected',
      `${fall.reason} Confidence ${Math.round(fall.confidence * 100)}%.`
    );
    // Ask before escalating. The wearer gets the countdown to say they are fine.
    openCheckIn(reading.deviceId, {
      reason: 'Possible fall detected',
      at: new Date(now),
      fall: { reason: fall.reason, confidence: fall.confidence, stages: fall.stages },
    });
  }

  const checkIn = checkInStatus(reading.deviceId, { now: new Date(now) });
  if (checkIn.state === 'escalated' && !s.escalationAnnounced) {
    s.escalationAnnounced = true;
    push(
      'fall_no_response',
      'critical',
      'No response after a possible fall',
      `The wearer did not respond within ${checkIn.windowSeconds}s of the check-in.`
    );
  }
  if (checkIn.state === 'none' || checkIn.state === 'resolved') {
    s.escalationAnnounced = false;
  }

  // --- SpO2: hypoxia. Critical below the lower bound, with no sustain window
  //     at the critical level because desaturation is not something to wait out.
  if (reading.spo2 != null && reading.signalOk !== false) {
    if (reading.spo2 < t.spo2Critical) {
      push(
        'hypoxia',
        'critical',
        `Blood oxygen critically low (${reading.spo2}%)`,
        `Below the ${t.spo2Critical}% critical threshold. Seek medical help.`
      );
    } else if (reading.spo2 < t.spo2Low) {
      const held = sustainedFor(s, 'spo2_low', true, now);
      if (held >= sustainMs) {
        push(
          'hypoxia',
          'critical',
          `Blood oxygen low (${reading.spo2}%)`,
          `Held below ${t.spo2Low}% for ${Math.round(held / 1000)}s.`
        );
      }
    } else {
      sustainedFor(s, 'spo2_low', false, now);
    }
  }

  // --- Heart rate: must hold for the sustain window (brief: 30s) so that a
  //     single motion-corrupted PPG sample doesn't page a caregiver. ---
  if (reading.heartRate != null && reading.signalOk !== false) {
    const high = reading.heartRate > t.hrHigh;
    const low = reading.heartRate < t.hrLow;

    const highHeld = sustainedFor(s, 'hr_high', high, now);
    const lowHeld = sustainedFor(s, 'hr_low', low, now);

    if (high && highHeld >= sustainMs) {
      push(
        'tachycardia',
        'warning',
        `Heart rate elevated (${reading.heartRate} bpm)`,
        `Above ${t.hrHigh} bpm for ${Math.round(highHeld / 1000)}s.`
      );
    }
    if (low && lowHeld >= sustainMs) {
      push(
        'bradycardia',
        'warning',
        `Heart rate low (${reading.heartRate} bpm)`,
        `Below ${t.hrLow} bpm for ${Math.round(lowHeld / 1000)}s.`
      );
    }
  }

  // --- Personal baseline: an excursion above the wearer's own resting rate.
  //     This is the rule the fixed thresholds cannot express — a wearer who
  //     rests at 52 bpm sitting at 95 is a 43 bpm excursion that never touches
  //     the 120 bpm ceiling. Restricted to rest (walking would fire it
  //     constantly) and to a mature baseline, and deliberately scoped to what
  //     the absolute rule misses so the two never double-report the same beat.
  if (
    reading.heartRate != null &&
    reading.signalOk !== false &&
    baselineReady(s) &&
    isAtRest(reading)
  ) {
    const excursion = reading.heartRate - s.restingHr;
    const elevated = reading.heartRate <= t.hrHigh && excursion > RELATIVE_HR_DELTA;
    const held = sustainedFor(s, 'hr_above_baseline', elevated, now);

    if (elevated && held >= sustainMs) {
      push(
        'hr_above_baseline',
        'warning',
        `Heart rate well above your resting rate (${reading.heartRate} bpm)`,
        `${Math.round(excursion)} bpm above your learned resting rate of ` +
          `${Math.round(s.restingHr)} bpm while at rest, held ` +
          `${Math.round(held / 1000)}s. Still under the ${t.hrHigh} bpm ceiling.`
      );
    }
  } else {
    sustainedFor(s, 'hr_above_baseline', false, now);
  }

  // --- Heat stress: the cross-referencing rule. Prefer the device's own
  //     ambient sensor (it is where the body actually is); fall back to the
  //     weather API when the device has no DHT22 or reports nothing. ---
  const ambientTemp = reading.ambientTemp ?? ambient?.tempC ?? null;
  const humidity = reading.humidity ?? ambient?.humidity ?? null;
  const envSource = reading.ambientTemp != null ? 'device' : ambient ? ambient.source : 'none';

  const heat = assessHeatStress({
    heartRate: reading.heartRate,
    ambientTemp,
    humidity,
    restingHr: s.restingHr ?? 70,
  });

  if (heat.severity) {
    const held = sustainedFor(s, 'heat', true, now);
    // Environment changes slowly, so require half the sustain window to avoid
    // firing on one hot sample, but don't make the wearer wait a full 30s.
    if (held >= sustainMs / 2 || heat.severity === 'critical') {
      push('heat_stress', heat.severity, `Heat-stress risk: ${heat.band.label}`, `${heat.reason} (source: ${envSource})`);
    }
  } else {
    sustainedFor(s, 'heat', false, now);
  }

  // --- Air quality: enrichment only, needs the weather API. ---
  const air = assessAirQuality({ aqi: ambient?.aqi, pm25: ambient?.pm25 });
  if (air.severity === 'warning') {
    push('air_quality', 'warning', `Air quality: ${air.label}`, air.reason);
  }

  // --- Learned model: reconstruction error against the wearer's normal.
  //     Runs after the rules and never suppresses them — it is an extra
  //     signal, not a replacement. See ml/README.md for how it was trained. ---
  const ml = scoreReading(reading);
  if (ml) {
    const far = ml.ratio >= ML_ALERT_RATIO;
    const held = sustainedFor(s, 'ml', far, now);
    if (far && held >= sustainMs) {
      push(
        'ml_anomaly',
        'warning',
        'Unusual vital-sign pattern',
        `Learned model reconstruction error ${ml.ratio.toFixed(1)}x the normal threshold, held ${Math.round(held / 1000)}s. This flags deviation from your baseline, not a diagnosis.`
      );
    }
  } else {
    sustainedFor(s, 'ml', false, now);
  }

  const derived = {
    heatIndex: heat.heatIndex,
    heatIndexExtrapolated: heat.heatIndexExtrapolated,
    heatBand: heat.band.level,
    heatBandLabel: heat.band.label,
    strain: heat.strain,
    restingHr: s.restingHr == null ? null : Math.round(s.restingHr),
    baselineReady: baselineReady(s),
    fall: fall.fall
      ? { detected: true, confidence: fall.confidence, stages: fall.stages, source: fall.source }
      : { detected: false },
    checkIn: {
      state: checkIn.state,
      remainingSeconds: checkIn.remainingSeconds ?? 0,
      windowSeconds: checkIn.windowSeconds ?? null,
    },
    hrHigh: t.hrHigh,
    hrHighSource: t.hrHighSource,
    airQuality: air.label,
    envSource,
    mlScore: ml ? Number(ml.score.toFixed(5)) : null,
    mlRatio: ml ? Number(ml.ratio.toFixed(2)) : null,
    mlAnomalous: ml ? ml.anomalous : null,
  };

  return { alerts, derived };
}

export { heatIndexC };
