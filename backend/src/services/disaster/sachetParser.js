import { Severity } from './types.js';

/**
 * Parser for NDMA SACHET's FetchAllAlertDetails payload.
 *
 * Pure and network-free so it can be checked against a captured response.
 * Everything here is shaped by what the live feed actually returns, not by
 * what the CAP standard says it should:
 *
 *   - timestamps are Java's `Date.toString()` with an IST zone label, which
 *     `new Date()` rejects outright as Invalid Date
 *   - `severity` mixes colour names ("Yellow", "Orange") with alert levels
 *     ("WATCH", "ALERT", "WARNING") in the same field
 *   - `severity_level` mixes trend words ("rising", "falling", "steady") with
 *     likelihood ("Likely", "Very Likely"), and varies in case
 *   - `centroid` is "longitude,latitude" — the reverse of the usual order
 *   - `area_description` carries stray trailing whitespace
 *   - the feed is multilingual; en/hi/pa/or all appear in one response
 */

const IST_OFFSET_MS = 5.5 * 60 * 60 * 1000;

const MONTHS = {
  Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5,
  Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11,
};

const STAMP_RE =
  /^\w{3}\s+(\w{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+([A-Za-z]{2,5})\s+(\d{4})$/;

/**
 * Parses "Wed Sep 02 19:43:00 IST 2026".
 *
 * Any zone other than IST returns null rather than a guess: silently assuming
 * an offset would shift an alert's expiry by hours, and an alert that expires
 * at the wrong time is worse than one we admit we cannot read.
 *
 * @returns {Date|null}
 */
export function parseIstTimestamp(value) {
  if (typeof value !== 'string') return null;
  const m = value.trim().match(STAMP_RE);
  if (!m) return null;

  const [, mon, day, hh, mm, ss, zone, year] = m;
  if (zone.toUpperCase() !== 'IST') return null;

  const month = MONTHS[mon];
  if (month === undefined) return null;

  const ms = Date.UTC(Number(year), month, Number(day), Number(hh), Number(mm), Number(ss));
  if (Number.isNaN(ms)) return null;
  return new Date(ms - IST_OFFSET_MS);
}

/**
 * Normalises SACHET's two competing severity fields onto one scale.
 *
 * `severity_color` is preferred because it is the consistent one (yellow /
 * orange / red across the whole feed), and it matches IMD's published colour
 * code: yellow = watch, orange = be prepared, red = take action.
 */
export function normaliseSeverity({ severity, severityColor }) {
  const colour = String(severityColor ?? '').trim().toLowerCase();
  if (colour === 'red') return Severity.SEVERE;
  if (colour === 'orange') return Severity.MODERATE;
  if (colour === 'yellow') return Severity.MINOR;

  const token = String(severity ?? '').trim().toLowerCase();
  if (token === 'warning' || token === 'red') return Severity.SEVERE;
  if (token === 'alert' || token === 'orange') return Severity.MODERATE;
  if (token === 'watch' || token === 'yellow') return Severity.MINOR;

  return Severity.UNKNOWN;
}

/** "longitude,latitude" -> {lat, lon}. Returns null if either is unusable. */
export function parseCentroid(value) {
  if (typeof value !== 'string') return null;
  const parts = value.split(',');
  if (parts.length !== 2) return null;

  // SACHET writes longitude first. Reading it as lat/lon puts every Indian
  // alert in the Indian Ocean, which the distance filter would silently accept.
  const lon = Number(parts[0]);
  const lat = Number(parts[1]);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
  return { lat, lon };
}

/** Great-circle distance in km. */
export function distanceKm(a, b) {
  const R = 6371;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}

/**
 * Coarse hazard grouping, so downstream code can ask "is there a heat hazard
 * near this wearer" without matching on free text. SACHET's `disaster_type`
 * is a human label with no fixed vocabulary, so this is best-effort and always
 * falls back to `other` rather than guessing.
 */
export function classifyHazard(disasterType) {
  const t = String(disasterType ?? '').toLowerCase();
  if (!t) return 'unknown';
  if (t.includes('heat')) return 'heat';
  if (t.includes('cold') || t.includes('cold wave')) return 'cold';
  if (t.includes('flood')) return 'flood';
  if (t.includes('cyclone')) return 'cyclone';
  if (t.includes('rain') || t.includes('thunder') || t.includes('lightning')) return 'storm';
  if (t.includes('earthquake')) return 'earthquake';
  if (t.includes('tsunami')) return 'tsunami';
  if (t.includes('landslide')) return 'landslide';
  if (t.includes('wind') || t.includes('gale')) return 'wind';
  return 'other';
}

/**
 * Turns one raw feed entry into a normalised alert, or null when it cannot be
 * trusted. A row with an unreadable start time is dropped rather than
 * defaulted to now: dating an alert wrongly is worse than not showing it.
 */
export function parseAlert(raw) {
  if (!raw || typeof raw !== 'object') return null;

  const identifier = raw.identifier ?? raw.alert_id_sdma_autoinc;
  if (identifier == null) return null;

  const startsAt = parseIstTimestamp(raw.effective_start_time);
  const endsAt = parseIstTimestamp(raw.effective_end_time);
  if (!startsAt) return null;

  const message = String(raw.warning_message ?? '').trim();
  const disasterType = String(raw.disaster_type ?? '').trim();
  if (!message && !disasterType) return null;

  return {
    id: String(identifier),
    hazard: classifyHazard(disasterType),
    disasterType: disasterType || 'Unknown',
    severity: normaliseSeverity({
      severity: raw.severity,
      severityColor: raw.severity_color,
    }),
    // Kept verbatim alongside the normalised value so the UI can show what the
    // agency actually published, not only our interpretation of it.
    rawSeverity: raw.severity ?? null,
    severityColour: raw.severity_color ?? null,
    message,
    // The feed leaves stray whitespace in this field.
    area: String(raw.area_description ?? '').trim() || null,
    areaKm2: Number.isFinite(Number(raw.area_covered)) ? Number(raw.area_covered) : null,
    centroid: parseCentroid(raw.centroid),
    language: String(raw.actual_lang ?? '').trim().toLowerCase() || 'unknown',
    issuedBy: String(raw.alert_source ?? '').trim() || 'NDMA SACHET',
    startsAt,
    endsAt,
  };
}

/**
 * Parses a whole FetchAllAlertDetails response.
 *
 * @param {unknown} payload  decoded JSON
 * @param {object} [opts]
 * @param {Date}   [opts.now]        clock, injectable for tests
 * @param {string} [opts.language]   keep only this language ('*' for all)
 * @param {boolean}[opts.activeOnly] drop alerts whose end time has passed
 * @returns {{alerts: object[], skipped: number, total: number}}
 */
export function parseSachetPayload(payload, { now = new Date(), language = 'en', activeOnly = true } = {}) {
  if (!Array.isArray(payload)) return { alerts: [], skipped: 0, total: 0 };

  let skipped = 0;
  const alerts = [];

  for (const raw of payload) {
    const alert = parseAlert(raw);
    if (!alert) {
      skipped += 1;
      continue;
    }
    if (language !== '*' && alert.language !== language) continue;
    // An alert with no readable end time is kept: SACHET is the authority on
    // whether it still applies, and dropping it would hide a real warning.
    if (activeOnly && alert.endsAt && alert.endsAt.getTime() < now.getTime()) continue;
    alerts.push(alert);
  }

  alerts.sort((a, b) => b.startsAt.getTime() - a.startsAt.getTime());
  return { alerts, skipped, total: payload.length };
}
