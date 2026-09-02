import 'dotenv/config';

const bool = (v, d = false) => (v == null || v === '' ? d : /^(1|true|yes|on)$/i.test(String(v)));
const num = (v, d) => (v == null || v === '' || Number.isNaN(Number(v)) ? d : Number(v));

let weatherMock = null;
if (process.env.WEATHER_MOCK) {
  try {
    weatherMock = JSON.parse(process.env.WEATHER_MOCK);
  } catch {
    console.warn('[config] WEATHER_MOCK is not valid JSON — ignoring it.');
  }
}

export const config = {
  port: num(process.env.PORT, 4000),
  // Bind explicitly to IPv4 so ESP32 clients on the Wi-Fi LAN do not depend
  // on the OS mapping an IPv6 wildcard socket back to IPv4.
  host: process.env.HOST || '0.0.0.0',
  corsOrigin: process.env.CORS_ORIGIN || '*',

  // PostgreSQL (Supabase). Blank -> in-memory store.
  databaseUrl: process.env.DATABASE_URL || '',
  dbSsl: !(process.env.DATABASE_SSL === 'false'),
  dbPoolMax: num(process.env.DATABASE_POOL_MAX, 5),

  deviceApiKey: process.env.DEVICE_API_KEY || '',

  weather: {
    apiKey: process.env.OPENWEATHER_API_KEY || '',
    lat: num(process.env.DEFAULT_LAT, 22.5726),
    lon: num(process.env.DEFAULT_LON, 88.3639),
    mock: weatherMock,
    ttlMs: num(process.env.WEATHER_TTL_MS, 10 * 60 * 1000),
  },

  // NDMA SACHET disaster context. Enrichment only: every state of this feed,
  // including total absence, leaves the health rules working unchanged.
  disaster: {
    enabled: process.env.DISASTER_ENABLED !== 'false',
    url:
      process.env.SACHET_URL ||
      'https://sachet.ndma.gov.in/cap_public_website/FetchAllAlertDetails',
    // Below this age a successful fetch is reported LIVE.
    liveWindowMs: num(process.env.DISASTER_LIVE_WINDOW_MS, 30 * 60 * 1000),
    // Past this, cached data is labelled STALE rather than merely CACHED.
    maxAgeMs: num(process.env.DISASTER_MAX_AGE_MS, 6 * 60 * 60 * 1000),
    // How often a fetch may be attempted at all.
    refreshMs: num(process.env.DISASTER_REFRESH_MS, 15 * 60 * 1000),
    timeoutMs: num(process.env.DISASTER_TIMEOUT_MS, 8000),
    // Only alerts whose centroid is within this radius of the wearer.
    radiusKm: num(process.env.DISASTER_RADIUS_KM, 200),
    language: process.env.DISASTER_LANGUAGE || 'en',
    // Serve the bundled sample when the network has never succeeded. Always
    // labelled as a sample; it can never be reported as live.
    allowSample: process.env.DISASTER_ALLOW_SAMPLE !== 'false',
  },

  sms: {
    provider: (process.env.SMS_PROVIDER || 'console').toLowerCase(),
    emergencyContact: process.env.EMERGENCY_CONTACT || '',
    fast2smsKey: process.env.FAST2SMS_API_KEY || '',
    twilio: {
      sid: process.env.TWILIO_ACCOUNT_SID || '',
      token: process.env.TWILIO_AUTH_TOKEN || '',
      from: process.env.TWILIO_FROM || '',
    },
    // Don't re-SMS the same alert type for this long.
    cooldownMs: num(process.env.SMS_COOLDOWN_MS, 5 * 60 * 1000),
  },

  alerts: {
    // Don't re-raise the same alert type for this long.
    cooldownMs: num(process.env.ALERT_COOLDOWN_MS, 60 * 1000),
    // How long an out-of-range vital must persist before it counts (brief: 30s).
    sustainWindowMs: num(process.env.SUSTAIN_WINDOW_MS, 30 * 1000),
  },

  verbose: bool(process.env.VERBOSE, true),
};

export default config;
