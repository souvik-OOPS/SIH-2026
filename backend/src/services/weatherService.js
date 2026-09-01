import config from '../config.js';

/**
 * Ambient conditions from OpenWeather (current weather + air quality).
 *
 * Three modes, in priority order:
 *   1. WEATHER_MOCK env is set   -> return it verbatim (stage demos, "simulate a heatwave")
 *   2. OPENWEATHER_API_KEY is set -> live fetch, cached for config.weather.ttlMs
 *   3. neither                    -> return null, and the caller falls back to the
 *                                    device's own DHT22 reading
 *
 * Mode 3 matters: the whole point of the problem statement is that this works
 * when connectivity is gone. The on-board sensor is the source of truth; the
 * API is enrichment (it adds AQI, which the DHT22 cannot measure).
 */

const cache = new Map(); // key -> { at: number, data: object }

// Runtime override, settable from the API for demos without a server restart.
let runtimeOverride = null;

export function setWeatherOverride(payload) {
  runtimeOverride = payload;
  return runtimeOverride;
}

export function getWeatherOverride() {
  return runtimeOverride;
}

export function clearWeatherOverride() {
  runtimeOverride = null;
}

const key = (lat, lon) => `${lat.toFixed(3)},${lon.toFixed(3)}`;

async function fetchJson(url, timeoutMs = 6000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

/**
 * @returns {Promise<null | {tempC, humidity, aqi, pm25, description, source, fetchedAt}>}
 */
export async function getAmbientConditions({ lat, lon } = {}) {
  if (runtimeOverride) return { ...runtimeOverride, source: runtimeOverride.source || 'override' };
  if (config.weather.mock) return { ...config.weather.mock, source: config.weather.mock.source || 'mock' };
  if (!config.weather.apiKey) return null;

  const la = lat ?? config.weather.lat;
  const lo = lon ?? config.weather.lon;
  const k = key(la, lo);

  const hit = cache.get(k);
  if (hit && Date.now() - hit.at < config.weather.ttlMs) return hit.data;

  try {
    const base = 'https://api.openweathermap.org/data/2.5';
    const [weather, air] = await Promise.allSettled([
      fetchJson(`${base}/weather?lat=${la}&lon=${lo}&units=metric&appid=${config.weather.apiKey}`),
      fetchJson(`${base}/air_pollution?lat=${la}&lon=${lo}&appid=${config.weather.apiKey}`),
    ]);

    const w = weather.status === 'fulfilled' ? weather.value : null;
    const a = air.status === 'fulfilled' ? air.value : null;

    if (!w && !a) throw new Error('both OpenWeather endpoints failed');

    const data = {
      tempC: w?.main?.temp ?? null,
      humidity: w?.main?.humidity ?? null,
      feelsLikeC: w?.main?.feels_like ?? null,
      description: w?.weather?.[0]?.description ?? null,
      aqi: a?.list?.[0]?.main?.aqi ?? null,
      pm25: a?.list?.[0]?.components?.pm2_5 ?? null,
      pm10: a?.list?.[0]?.components?.pm10 ?? null,
      lat: la,
      lon: lo,
      source: 'openweather',
      fetchedAt: new Date().toISOString(),
    };

    cache.set(k, { at: Date.now(), data });
    return data;
  } catch (err) {
    console.warn(`[weather] lookup failed (${err.message}) — falling back to on-device sensors.`);
    // Serve a stale cache entry rather than nothing; ambient conditions move slowly.
    return hit?.data ?? null;
  }
}
