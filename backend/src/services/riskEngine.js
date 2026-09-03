/**
 * Risk engine.
 *
 * Turns the individual rule outcomes into one level a person can act on. It is
 * deliberately a deterministic reducer, not a model: every level it reports can
 * be traced to the named factors that produced it, which is what makes it
 * defensible to explain to a wearer and to a judge.
 *
 * Design rules, in order of importance:
 *
 *   1. It never *lowers* what a rule already decided. The worst contributing
 *      factor sets the floor. A risk engine that can talk a critical alert down
 *      to "caution" is a liability, not a feature.
 *   2. Poor signal reduces *confidence*, never severity. Untrustworthy data is
 *      a reason to say "we are not sure", not a reason to stand down.
 *   3. Absent inputs produce `unknown`, never `normal`. Silence is not safety.
 */

export const RiskLevel = {
  UNKNOWN: 'unknown',
  NORMAL: 'normal',
  CAUTION: 'caution',
  WARNING: 'warning',
  CRITICAL: 'critical',
};

export const RISK_RANK = {
  [RiskLevel.UNKNOWN]: -1,
  [RiskLevel.NORMAL]: 0,
  [RiskLevel.CAUTION]: 1,
  [RiskLevel.WARNING]: 2,
  [RiskLevel.CRITICAL]: 3,
};

const SEVERITY_TO_RISK = {
  critical: RiskLevel.CRITICAL,
  warning: RiskLevel.WARNING,
  info: RiskLevel.CAUTION,
};

const worst = (a, b) => (RISK_RANK[b] > RISK_RANK[a] ? b : a);

/**
 * @param {object}   input
 * @param {object[]} input.alerts        alerts raised for this reading
 * @param {object}   input.reading       the sample
 * @param {object}   input.derived       output of the rule pass
 * @param {object}   [input.fall]        fall verdict, if any
 * @param {object}   [input.nonResponse] non-response state, if any
 * @param {object}   [input.disaster]    cached disaster context, if any
 * @returns {{level: string, confidence: string, factors: object[], summary: string}}
 */
export function assessRisk({
  alerts = [],
  reading = {},
  derived = {},
  fall = null,
  nonResponse = null,
  disaster = null,
} = {}) {
  const factors = [];
  let level = RiskLevel.NORMAL;

  const add = (code, contributes, detail) => {
    factors.push({ code, level: contributes, detail });
    level = worst(level, contributes);
  };

  // --- what the rules already decided (the floor)
  for (const alert of alerts) {
    const mapped = SEVERITY_TO_RISK[alert.severity] ?? RiskLevel.CAUTION;
    add(alert.type, mapped, alert.message);
  }

  // --- an unanswered fall outranks everything else
  if (nonResponse?.state === 'escalated') {
    add(
      'fall_no_response',
      RiskLevel.CRITICAL,
      'A possible fall went unanswered for the full check-in window.'
    );
  } else if (nonResponse?.state === 'awaiting') {
    add('fall_awaiting_response', RiskLevel.CRITICAL, 'Waiting for the wearer to confirm they are okay.');
  } else if (fall?.fall) {
    add('fall', RiskLevel.CRITICAL, fall.reason ?? 'A possible fall was detected.');
  }

  // --- environment, as context rather than a verdict
  if (derived.heatBand === 'danger' || derived.heatBand === 'extreme_danger') {
    add('heat_environment', RiskLevel.WARNING, `Heat-index band: ${derived.heatBandLabel}.`);
  } else if (derived.heatBand === 'caution' || derived.heatBand === 'extreme_caution') {
    add('heat_environment', RiskLevel.CAUTION, `Heat-index band: ${derived.heatBandLabel}.`);
  }

  // Official disaster context nudges caution but never decides risk on its own:
  // a cyclone warning for the district is not a statement about this wearer.
  if (disaster?.highestSeverity === 'severe' && disaster.count > 0) {
    add(
      'disaster_context',
      RiskLevel.CAUTION,
      `${disaster.count} official alert(s) in the area, most severe: ${disaster.highestSeverity}.`
    );
  }

  // --- confidence, which is a separate axis from severity
  let confidence = 'high';
  const reasons = [];

  if (reading.signalOk === false) {
    confidence = 'low';
    reasons.push('sensor signal was marked unreliable');
  }
  if (reading.heartRate == null && reading.spo2 == null) {
    confidence = 'low';
    reasons.push('no heart-rate or SpO2 reading');
  } else if (reading.heartRate == null || reading.spo2 == null) {
    if (confidence === 'high') confidence = 'medium';
    reasons.push('one vital is missing');
  }
  if (derived.baselineReady === false) {
    if (confidence === 'high') confidence = 'medium';
    reasons.push('personal baseline is still being learned');
  }

  // --- nothing to go on at all
  const hasAnyVital = reading.heartRate != null || reading.spo2 != null;
  if (!hasAnyVital && alerts.length === 0 && !fall?.fall && !nonResponse) {
    return {
      level: RiskLevel.UNKNOWN,
      confidence: 'low',
      factors: [
        {
          code: 'no_data',
          level: RiskLevel.UNKNOWN,
          detail: 'No vitals available, so no assessment was made. This is not an all-clear.',
        },
      ],
      confidenceReasons: reasons,
      summary: 'No assessment — no usable vitals were received.',
    };
  }

  factors.sort((a, b) => RISK_RANK[b.level] - RISK_RANK[a.level]);

  return {
    level,
    confidence,
    confidenceReasons: reasons,
    factors,
    summary: summarise(level, confidence, factors),
  };
}

function summarise(level, confidence, factors) {
  const top = factors.find((f) => f.level === level);
  const caveat = confidence === 'low' ? ' Readings may be unreliable.' : '';

  switch (level) {
    case RiskLevel.CRITICAL:
      return `Critical: ${top?.detail ?? 'a critical condition was detected.'}${caveat}`;
    case RiskLevel.WARNING:
      return `Warning: ${top?.detail ?? 'a warning condition is active.'}${caveat}`;
    case RiskLevel.CAUTION:
      return `Caution: ${top?.detail ?? 'conditions worth watching.'}${caveat}`;
    case RiskLevel.NORMAL:
      return `No active warnings.${caveat}`;
    default:
      return 'No assessment available.';
  }
}
