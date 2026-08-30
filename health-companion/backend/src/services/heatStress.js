/**
 * Heat-stress maths.
 *
 * The brief's v1 rule was "ambientTemp > 40 AND humidity > 60". That misses the
 * actual physiology: 38 C at 80% RH is more dangerous than 42 C at 20% RH,
 * because sweat can't evaporate. So we compute the NOAA Heat Index (apparent
 * temperature) instead and band it. Same amount of code, defensible on a slide.
 *
 * Reference: NOAA/NWS Rothfusz regression.
 * https://www.wpc.ncep.noaa.gov/html/heatindex_equation.shtml
 */

const cToF = (c) => (c * 9) / 5 + 32;
const fToC = (f) => ((f - 32) * 5) / 9;

// The Rothfusz regression is fitted for roughly 80-112 F dry-bulb. Past that it
// extrapolates hard (44 C / 65% RH "computes" to ~67 C, which is not a real
// apparent temperature). We clamp the reported value to the top of the NWS
// published chart and flag it, rather than putting a nonsense number on screen.
export const HI_VALID_MAX_C = 58; // ~137 F, the ceiling of the NWS chart

/**
 * @param {number} tempC ambient dry-bulb temperature, Celsius
 * @param {number} rh relative humidity, percent (0-100)
 * @returns {number|null} apparent temperature in Celsius, clamped to HI_VALID_MAX_C
 */
export function heatIndexC(tempC, rh) {
  if (tempC == null || rh == null || Number.isNaN(tempC) || Number.isNaN(rh)) return null;

  const T = cToF(tempC);
  const R = Math.min(100, Math.max(0, rh));

  // Below ~80 F the regression overshoots; NWS uses this simple form instead.
  const simple = 0.5 * (T + 61.0 + (T - 68.0) * 1.2 + R * 0.094);
  if ((simple + T) / 2 < 80) return round1(fToC((simple + T) / 2));

  let HI =
    -42.379 +
    2.04901523 * T +
    10.14333127 * R -
    0.22475541 * T * R -
    0.00683783 * T * T -
    0.05481717 * R * R +
    0.00122874 * T * T * R +
    0.00085282 * T * R * R -
    0.00000199 * T * T * R * R;

  // NWS adjustments at the humidity extremes.
  if (R < 13 && T >= 80 && T <= 112) {
    HI -= ((13 - R) / 4) * Math.sqrt((17 - Math.abs(T - 95)) / 17);
  } else if (R > 85 && T >= 80 && T <= 87) {
    HI += ((R - 85) / 10) * ((87 - T) / 5);
  }

  return round1(Math.min(fToC(HI), HI_VALID_MAX_C));
}

/** True when the inputs sit outside the regression's fitted range. */
export function heatIndexExtrapolated(tempC, rh) {
  if (tempC == null || rh == null) return false;
  const T = cToF(tempC);
  return T > 112 || T < 80;
}

const round1 = (n) => Math.round(n * 10) / 10;

/** NOAA heat-index risk bands, in Celsius. */
export function heatIndexBand(hiC) {
  if (hiC == null) return { level: 'unknown', label: 'Unknown', severity: null };
  if (hiC < 27) return { level: 'safe', label: 'Safe', severity: null };
  if (hiC < 32) return { level: 'caution', label: 'Caution', severity: 'info' };
  if (hiC < 39) return { level: 'extreme_caution', label: 'Extreme caution', severity: 'warning' };
  if (hiC < 51) return { level: 'danger', label: 'Danger', severity: 'warning' };
  return { level: 'extreme_danger', label: 'Extreme danger', severity: 'critical' };
}

/**
 * Cardiovascular strain: heart rate as a fraction of the wearer's reserve above
 * resting. A cheap stand-in for %HRmax that needs no age input.
 * Returns 0..1+ where >0.6 sustained in the heat is the classic danger combo.
 */
export function strainIndex(heartRate, restingHr = 70, maxHr = 190) {
  if (heartRate == null) return null;
  const reserve = Math.max(1, maxHr - restingHr);
  return round2(Math.max(0, (heartRate - restingHr) / reserve));
}

const round2 = (n) => Math.round(n * 100) / 100;

/**
 * Combined heat-stress assessment: environment (heat index) AND the body's
 * response to it (elevated HR). Either alone is weaker evidence than both.
 */
export function assessHeatStress({ heartRate, ambientTemp, humidity, restingHr }) {
  const hi = heatIndexC(ambientTemp, humidity);
  const band = heatIndexBand(hi);
  const extrapolated = heatIndexExtrapolated(ambientTemp, humidity);
  const strain = strainIndex(heartRate, restingHr);

  const bodyElevated = strain != null && strain >= 0.45;
  const envRisky = ['extreme_caution', 'danger', 'extreme_danger'].includes(band.level);

  let severity = null;
  let reason = null;

  if (envRisky && bodyElevated) {
    severity = band.level === 'extreme_danger' ? 'critical' : 'warning';
    reason = `Heat index ${hi}°C (${band.label}) with heart rate ${heartRate} bpm — cardiovascular strain ${(strain * 100).toFixed(0)}% of reserve.`;
  } else if (band.level === 'extreme_danger') {
    severity = 'warning';
    reason = `Heat index ${hi}°C — ${band.label}. Exposure is unsafe regardless of current activity.`;
  }

  return { heatIndex: hi, heatIndexExtrapolated: extrapolated, band, strain, severity, reason };
}

/** OpenWeather air_pollution index (1-5) -> respiratory risk. */
export function assessAirQuality({ aqi, pm25 }) {
  if (aqi == null && pm25 == null) return { severity: null, reason: null, label: 'Unknown' };

  const labels = { 1: 'Good', 2: 'Fair', 3: 'Moderate', 4: 'Poor', 5: 'Very poor' };
  const label = labels[aqi] || 'Unknown';

  // WHO 24h guideline is 15 ug/m3; CPCB's national standard is 60.
  if (aqi >= 5 || (pm25 != null && pm25 > 120)) {
    return { severity: 'warning', label, reason: `Air quality ${label}${pm25 != null ? ` (PM2.5 ${pm25} ug/m3)` : ''} — respiratory risk is high.` };
  }
  if (aqi >= 4 || (pm25 != null && pm25 > 60)) {
    return { severity: 'info', label, reason: `Air quality ${label}${pm25 != null ? ` (PM2.5 ${pm25} ug/m3)` : ''} — limit outdoor exertion.` };
  }
  return { severity: null, label, reason: null };
}
