import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  openCheckIn,
  checkInStatus,
  respondOk,
  clearCheckIn,
  resetNonResponse,
  NonResponseState,
} from '../src/services/nonResponse.js';

describe('nonResponse Service Tests', () => {
  const deviceId = 'test-device-nr';

  beforeEach(() => {
    resetNonResponse();
  });

  it('returns state NONE when no incident is open', () => {
    const status = checkInStatus(deviceId);
    assert.equal(status.state, NonResponseState.NONE);
  });

  it('opens a new check-in and enters AWAITING state', () => {
    const now = new Date(1000000000000);
    const incident = openCheckIn(deviceId, { reason: 'Test fall', at: now });

    assert.equal(incident.state, NonResponseState.AWAITING);
    assert.equal(incident.reason, 'Test fall');

    const status = checkInStatus(deviceId, { now });
    assert.equal(status.state, NonResponseState.AWAITING);
    assert.ok(status.remainingSeconds > 0);
  });

  it('is idempotent when a check-in is already awaiting', () => {
    const now1 = new Date(1000000000000);
    const now2 = new Date(1000000005000);
    const inc1 = openCheckIn(deviceId, { reason: 'First', at: now1 });
    const inc2 = openCheckIn(deviceId, { reason: 'Second', at: now2 });

    assert.equal(inc1.id, inc2.id);
  });

  it('resolves when wearer responds OK before expiry', () => {
    const start = new Date(1000000000000);
    openCheckIn(deviceId, { at: start });

    const responseTime = new Date(start.getTime() + 10000); // 10s later (within 30s window)
    const result = respondOk(deviceId, { now: responseTime });

    assert.equal(result.ok, true);
    assert.equal(result.status.state, NonResponseState.RESOLVED);
  });

  it('escalates when check-in expires without response', () => {
    const start = new Date(1000000000000);
    openCheckIn(deviceId, { at: start });

    const expiredTime = new Date(start.getTime() + 35000); // 35s later (>30s window)
    const status = checkInStatus(deviceId, { now: expiredTime });

    assert.equal(status.state, NonResponseState.ESCALATED);
  });

  it('rejects OK response after expiry/escalation', () => {
    const start = new Date(1000000000000);
    openCheckIn(deviceId, { at: start });

    const expiredTime = new Date(start.getTime() + 35000);
    const result = respondOk(deviceId, { now: expiredTime });

    assert.equal(result.ok, false);
    assert.ok(result.reason.includes('closed and escalated'));
  });

  it('allows clearing closed incidents but not active ones', () => {
    const start = new Date(1000000000000);
    openCheckIn(deviceId, { at: start });

    // Active -> cannot clear
    assert.equal(clearCheckIn(deviceId), false);

    // Resolve it -> now can clear
    respondOk(deviceId, { now: new Date(start.getTime() + 5000) });
    assert.equal(clearCheckIn(deviceId), true);
    assert.equal(checkInStatus(deviceId).state, NonResponseState.NONE);
  });
});
