import config from '../config.js';

/**
 * SMS dispatch for critical alerts.
 *
 * Providers: console (default) | fast2sms | twilio
 *
 * 'console' is the default on purpose — the whole pipeline runs end to end with
 * no credentials, so a teammate can clone the repo and see alerts fire. Swap
 * SMS_PROVIDER only when you have keys.
 */

const lastSentAt = new Map(); // `${deviceId}:${type}` -> epoch ms

function onCooldown(deviceId, type) {
  const k = `${deviceId}:${type}`;
  const prev = lastSentAt.get(k);
  if (prev && Date.now() - prev < config.sms.cooldownMs) {
    return Math.ceil((config.sms.cooldownMs - (Date.now() - prev)) / 1000);
  }
  return 0;
}

function markSent(deviceId, type) {
  lastSentAt.set(`${deviceId}:${type}`, Date.now());
}

/** Fast2SMS wants a bare 10-digit Indian number; Twilio wants E.164. */
const toIndianLocal = (n) => String(n).replace(/\D/g, '').slice(-10);
const toE164 = (n) => {
  const digits = String(n).replace(/\D/g, '');
  if (String(n).trim().startsWith('+')) return `+${digits}`;
  return digits.length === 10 ? `+91${digits}` : `+${digits}`;
};

async function sendViaFast2Sms(to, body) {
  if (!config.sms.fast2smsKey) throw new Error('FAST2SMS_API_KEY is not set');
  const res = await fetch('https://www.fast2sms.com/dev/bulkV2', {
    method: 'POST',
    headers: {
      authorization: config.sms.fast2smsKey,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      route: 'q', // quick transactional route
      message: body,
      language: 'english',
      flash: 0,
      numbers: toIndianLocal(to),
    }),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || json.return === false) {
    throw new Error(json.message || `Fast2SMS HTTP ${res.status}`);
  }
  return { provider: 'fast2sms', id: json.request_id || null };
}

async function sendViaTwilio(to, body) {
  const { sid, token, from } = config.sms.twilio;
  if (!sid || !token || !from) throw new Error('Twilio credentials are incomplete');

  const form = new URLSearchParams({ To: toE164(to), From: from, Body: body });
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${Buffer.from(`${sid}:${token}`).toString('base64')}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: form,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.message || `Twilio HTTP ${res.status}`);
  return { provider: 'twilio', id: json.sid || null };
}

/**
 * Compose the SMS body. Kept under 160 chars so it stays a single segment.
 */
export function composeMessage(alert, device) {
  const who = device?.wearerName && device.wearerName !== 'Unknown wearer' ? device.wearerName : alert.deviceId;
  const time = new Date(alert.timestamp).toLocaleTimeString('en-IN', { hour12: false });
  let body = `HEALTH ALERT (${alert.severity.toUpperCase()}): ${who} - ${alert.message} at ${time}.`;
  if (body.length < 130 && alert.detail) body = `${body} ${alert.detail}`;
  return body.slice(0, 160);
}

/**
 * @returns {Promise<{sent: boolean, skipped?: string, error?: string, provider?: string}>}
 */
export async function sendAlertSms(alert, device) {
  const to = device?.emergencyContact || config.sms.emergencyContact;
  if (!to) return { sent: false, skipped: 'no emergency contact configured' };

  const cooling = onCooldown(alert.deviceId, alert.type);
  if (cooling) return { sent: false, skipped: `cooldown, ${cooling}s remaining` };

  const body = composeMessage(alert, device);

  try {
    let result;
    switch (config.sms.provider) {
      case 'fast2sms':
        result = await sendViaFast2Sms(to, body);
        break;
      case 'twilio':
        result = await sendViaTwilio(to, body);
        break;
      case 'console':
      default:
        console.log('\n' + '='.repeat(64));
        console.log(`  SMS (dry run -> ${to})`);
        console.log(`  ${body}`);
        console.log('='.repeat(64) + '\n');
        result = { provider: 'console', id: null };
        break;
    }
    markSent(alert.deviceId, alert.type);
    return { sent: true, ...result };
  } catch (err) {
    console.error(`[sms] send failed: ${err.message}`);
    return { sent: false, error: err.message, provider: config.sms.provider };
  }
}
