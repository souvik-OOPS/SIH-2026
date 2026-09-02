import config from '../config.js';

/**
 * Non-response check-in after a probable fall.
 *
 * "Are you okay?" with a countdown. If the wearer answers, the incident closes
 * and nothing escalates. If the window passes unanswered, it escalates.
 *
 * The state machine is driven by clock reads rather than a timer, so it behaves
 * identically whether readings arrive every second, arrive late, or stop
 * arriving altogether. A phone that goes quiet must still be able to escalate
 * when someone finally asks, which a setTimeout in a dead process cannot do.
 *
 * This module decides *that* an escalation is due. It never claims a message
 * was delivered — whether an SMS actually went out is recorded separately by
 * the code that tries to send one.
 */

const incidents = new Map(); // deviceId -> incident

export const NonResponseState = {
  NONE: 'none',
  AWAITING: 'awaiting',
  RESOLVED: 'resolved',
  ESCALATED: 'escalated',
};

export function resetNonResponse(deviceId) {
  if (deviceId) incidents.delete(deviceId);
  else incidents.clear();
}

/** Opens a check-in, unless one is already open for this device. */
export function openCheckIn(deviceId, { reason, at = new Date(), fall = null } = {}) {
  const existing = incidents.get(deviceId);
  if (existing && existing.state === NonResponseState.AWAITING) return existing;

  const incident = {
    id: `${deviceId}-${at.getTime()}`,
    deviceId,
    state: NonResponseState.AWAITING,
    reason: reason ?? 'Possible fall detected',
    openedAt: at,
    expiresAt: new Date(at.getTime() + config.fall.responseWindowMs),
    respondedAt: null,
    escalatedAt: null,
    fall,
  };
  incidents.set(deviceId, incident);
  return incident;
}

/**
 * Current state, advancing an expired check-in to escalated.
 *
 * Evaluating on read is what makes this safe: there is no scheduled callback to
 * miss, so an incident cannot sit silently unescalated because the process was
 * busy, restarted, or the device stopped reporting.
 */
export function checkInStatus(deviceId, { now = new Date() } = {}) {
  const incident = incidents.get(deviceId);
  if (!incident) return { state: NonResponseState.NONE };

  if (
    incident.state === NonResponseState.AWAITING &&
    now.getTime() >= incident.expiresAt.getTime()
  ) {
    incident.state = NonResponseState.ESCALATED;
    incident.escalatedAt = new Date(incident.expiresAt);
  }

  const remainingMs =
    incident.state === NonResponseState.AWAITING
      ? Math.max(0, incident.expiresAt.getTime() - now.getTime())
      : 0;

  return {
    state: incident.state,
    id: incident.id,
    reason: incident.reason,
    openedAt: incident.openedAt,
    expiresAt: incident.expiresAt,
    respondedAt: incident.respondedAt,
    escalatedAt: incident.escalatedAt,
    remainingMs,
    remainingSeconds: Math.ceil(remainingMs / 1000),
    windowSeconds: Math.round(config.fall.responseWindowMs / 1000),
    fall: incident.fall,
  };
}

/**
 * The wearer pressed "I'm OK".
 *
 * Refuses once the window has closed: by then an escalation may already have
 * gone out, and silently marking it resolved would leave a responder believing
 * the alert was retracted when nobody told them.
 */
export function respondOk(deviceId, { now = new Date() } = {}) {
  const incident = incidents.get(deviceId);
  if (!incident) return { ok: false, reason: 'no open check-in' };

  const status = checkInStatus(deviceId, { now });
  if (status.state === NonResponseState.ESCALATED) {
    return { ok: false, reason: 'the check-in window already closed and escalated', status };
  }
  if (status.state !== NonResponseState.AWAITING) {
    return { ok: false, reason: `check-in is ${status.state}`, status };
  }

  incident.state = NonResponseState.RESOLVED;
  incident.respondedAt = now;
  return { ok: true, status: checkInStatus(deviceId, { now }) };
}

/** Clears a closed incident so a later fall opens a fresh one. */
export function clearCheckIn(deviceId) {
  const incident = incidents.get(deviceId);
  if (!incident) return false;
  if (incident.state === NonResponseState.AWAITING) return false;
  incidents.delete(deviceId);
  return true;
}
