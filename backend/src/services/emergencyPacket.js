import { getBaseline } from './anomalyDetection.js';
import { checkInStatus, NonResponseState } from './nonResponse.js';

/**
 * The summary a responder actually needs, and nothing else.
 *
 * Deliberately narrow. A wearer's full history is not a responder's business,
 * so this carries the current state, the event that triggered it, and just
 * enough recent trend to show direction. Everything included has to earn its
 * place by changing what a responder would do on arrival.
 *
 * Specifically excluded: the full reading history, the alert log, wearer
 * identifiers beyond what the contact already knows, and any field the app
 * merely happens to hold. Location appears only when coordinates genuinely
 * exist on the device record — there is no fallback to a default or an
 * IP-derived guess, because a confidently wrong location is worse than none.
 */

/** How much recent trend is useful: enough to show direction, not a history. */
const TREND_SAMPLES = 6;

function trendOf(readings, key) {
  const values = readings
    .map((r) => r?.[key])
    .filter((v) => typeof v === 'number' && Number.isFinite(v));
  if (values.length < 2) return null;

  const first = values[0];
  const last = values[values.length - 1];
  const delta = last - first;
  const direction = Math.abs(delta) < 1 ? 'steady' : delta > 0 ? 'rising' : 'falling';

  return {
    direction,
    from: Math.round(first),
    to: Math.round(last),
    samples: values.length,
  };
}

/**
 * @param {object} input
 * @param {string} input.deviceId
 * @param {object} input.device        device record (for location + profile)
 * @param {object} input.reading       the current sample
 * @param {object} input.derived       rule-pass output
 * @param {object} input.risk          risk engine verdict
 * @param {object[]} [input.recent]    a few recent readings, newest last
 * @param {object} [input.disaster]    cached disaster context
 * @param {Date}   [input.now]
 */
export function buildEmergencyPacket({
  deviceId,
  device = null,
  reading = {},
  derived = {},
  risk = null,
  recent = [],
  disaster = null,
  now = new Date(),
} = {}) {
  const baseline = getBaseline(deviceId);
  const checkIn = checkInStatus(deviceId, { now });

  const hr = reading.heartRate ?? null;
  const restingHr = baseline.restingHr == null ? null : Math.round(baseline.restingHr);

  // Only meaningful once the baseline is actually learned; before that a
  // "deviation" is deviation from an arbitrary first sample.
  const baselineDeviation =
    hr != null && restingHr != null && baseline.ready
      ? { restingHr, currentHr: Math.round(hr), deltaBpm: Math.round(hr - restingHr) }
      : null;

  const event =
    checkIn.state === NonResponseState.ESCALATED
      ? {
          type: 'fall_no_response',
          detail: 'A possible fall was detected and the wearer did not respond to the check-in.',
          detectedAt: checkIn.openedAt,
          escalatedAt: checkIn.escalatedAt,
          fallReason: checkIn.fall?.reason ?? null,
          fallConfidence: checkIn.fall?.confidence ?? null,
        }
      : checkIn.state === NonResponseState.AWAITING
        ? {
            type: 'fall_awaiting_response',
            detail: 'A possible fall was detected. Waiting for the wearer to confirm.',
            detectedAt: checkIn.openedAt,
            secondsRemaining: checkIn.remainingSeconds,
            fallReason: checkIn.fall?.reason ?? null,
            fallConfidence: checkIn.fall?.confidence ?? null,
          }
        : risk?.level === 'critical'
          ? { type: 'critical_vitals', detail: risk.summary, detectedAt: now }
          : null;

  // Present only when the device record genuinely carries coordinates.
  const location =
    device?.lat != null && device?.lon != null
      ? { lat: Number(device.lat), lon: Number(device.lon), source: 'device record' }
      : null;

  return {
    generatedAt: now.toISOString(),
    deviceId,
    wearer: device?.wearerName ?? null,
    profile: device?.profile ?? null,
    age: device?.age ?? null,

    event,

    vitals: {
      heartRate: hr,
      spo2: reading.spo2 ?? null,
      ambientTemperature: reading.ambientTemp ?? null,
      humidity: reading.humidity ?? null,
      heatIndex: derived.heatIndex ?? null,
      // States plainly whether these numbers can be trusted, so a responder is
      // never handed a confident-looking vital the app already doubted.
      signalReliable: reading.signalOk !== false,
      measuredAt: reading.timestamp
        ? new Date(reading.timestamp).toISOString()
        : now.toISOString(),
    },

    baselineDeviation,

    risk: risk
      ? {
          level: risk.level,
          confidence: risk.confidence,
          summary: risk.summary,
          topFactors: (risk.factors ?? []).slice(0, 3).map((f) => ({
            code: f.code,
            level: f.level,
            detail: f.detail,
          })),
        }
      : null,

    recentTrend: {
      heartRate: trendOf(recent.slice(-TREND_SAMPLES), 'heartRate'),
      spo2: trendOf(recent.slice(-TREND_SAMPLES), 'spo2'),
      windowSamples: Math.min(recent.length, TREND_SAMPLES),
    },

    location,

    // Included only if already cached. Never fetched while building a packet:
    // an emergency summary must not block on a network call.
    disasterContext: disaster
      ? {
          freshness: disaster.freshness,
          isLive: disaster.isLive,
          attribution: disaster.attribution,
          count: disaster.count,
          highestSeverity: disaster.highestSeverity,
          top: disaster.alerts?.[0]
            ? {
                disasterType: disaster.alerts[0].disasterType,
                area: disaster.alerts[0].area,
                severity: disaster.alerts[0].severity,
              }
            : null,
        }
      : null,

    // What this packet is and is not, carried with it so the claim travels
    // alongside the data rather than living only in a UI caption.
    notes: {
      generatedOffline: true,
      deliveryClaim:
        'This packet was generated locally. It does not assert that any SMS, call, or network delivery took place.',
      dataScope:
        'Current state and a short recent trend only. No history, no alert log, no stored identifiers beyond the wearer name.',
    },
  };
}
