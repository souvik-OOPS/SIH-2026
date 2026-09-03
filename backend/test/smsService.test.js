import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { composeMessage, sendAlertSms } from '../src/services/smsService.js';

describe('smsService Tests', () => {
  it('composes single segment message under 160 chars', () => {
    const alert = {
      deviceId: 'band-01',
      severity: 'critical',
      message: 'Blood oxygen critically low (82%)',
      detail: 'Below 88% threshold. Seek immediate medical attention.',
      timestamp: new Date('2026-09-04T12:00:00Z'),
    };
    const device = {
      wearerName: 'Ramesh Patel',
    };

    const msg = composeMessage(alert, device);
    assert.ok(msg.length <= 160);
    assert.ok(msg.includes('HEALTH ALERT (CRITICAL)'));
    assert.ok(msg.includes('Ramesh Patel'));
    assert.ok(msg.includes('Blood oxygen critically low'));
  });

  it('handles alert without emergency contact gracefully', async () => {
    const alert = {
      deviceId: 'band-02',
      type: 'hypoxia',
      severity: 'critical',
      message: 'Critical vital alert',
      timestamp: new Date(),
    };

    const res = await sendAlertSms(alert, { emergencyContact: '' });
    assert.equal(res.sent, false);
    assert.ok(res.skipped.includes('no emergency contact'));
  });
});
