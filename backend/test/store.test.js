import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  connectStore,
  saveReading,
  listReadings,
  recentReadings,
  saveAlert,
  listAlerts,
  markAlertSms,
  acknowledgeAlert,
  upsertDevice,
  getDevice,
  listDevices,
  summariseStoredData,
  deleteDeviceData,
} from '../src/store.js';

describe('store Service (In-Memory fallback) Tests', () => {
  const deviceId = 'test-store-device';

  beforeEach(async () => {
    await deleteDeviceData(deviceId, { includeProfile: true });
  });

  describe('Readings Store', () => {
    it('saves and retrieves readings sorted by timestamp desc', async () => {
      const r1 = await saveReading({
        deviceId,
        heartRate: 70,
        spo2: 98,
        timestamp: new Date('2026-09-04T10:00:00Z'),
      });
      const r2 = await saveReading({
        deviceId,
        heartRate: 85,
        spo2: 96,
        timestamp: new Date('2026-09-04T10:01:00Z'),
      });

      assert.ok(r1._id);
      assert.ok(r2._id);

      const list = await listReadings(deviceId);
      assert.equal(list.length, 2);
      assert.equal(list[0].heartRate, 85); // Newest first
      assert.equal(list[1].heartRate, 70);
    });

    it('filters readings by since timestamp', async () => {
      await saveReading({
        deviceId,
        heartRate: 70,
        timestamp: new Date('2026-09-04T10:00:00Z'),
      });
      await saveReading({
        deviceId,
        heartRate: 85,
        timestamp: new Date('2026-09-04T10:05:00Z'),
      });

      const list = await listReadings(deviceId, { since: new Date('2026-09-04T10:02:00Z') });
      assert.equal(list.length, 1);
      assert.equal(list[0].heartRate, 85);
    });
  });

  describe('Alerts Store', () => {
    it('saves alert, marks SMS status, and acknowledges alert', async () => {
      const alert = await saveAlert({
        deviceId,
        type: 'hypoxia',
        severity: 'critical',
        message: 'SpO2 low',
        timestamp: new Date(),
      });

      assert.ok(alert._id);
      assert.equal(alert.smsSent, false);
      assert.equal(alert.acknowledged, false);

      // Mark SMS sent
      const patch = await markAlertSms(alert._id, { smsSent: true, smsNote: 'sent ok' });
      assert.equal(patch.smsSent, true);

      // Acknowledge
      const acked = await acknowledgeAlert(alert._id);
      assert.equal(acked.acknowledged, true);

      const alerts = await listAlerts(deviceId);
      assert.equal(alerts.length, 1);
      assert.equal(alerts[0].acknowledged, true);
      assert.equal(alerts[0].smsSent, true);
    });
  });

  describe('Devices Store', () => {
    it('upserts and retrieves device profile', async () => {
      const dev = await upsertDevice(deviceId, {
        wearerName: 'Sita Devi',
        profile: 'elderly',
        age: 72,
        emergencyContact: '9876543210',
      });

      assert.equal(dev.deviceId, deviceId);
      assert.equal(dev.wearerName, 'Sita Devi');
      assert.equal(dev.age, 72);

      const fetched = await getDevice(deviceId);
      assert.equal(fetched.wearerName, 'Sita Devi');
    });
  });

  describe('Privacy & Data Deletion', () => {
    it('summarises stored counts and deletes data correctly', async () => {
      await upsertDevice(deviceId, { wearerName: 'Test' });
      await saveReading({ deviceId, heartRate: 72, timestamp: new Date() });
      await saveAlert({ deviceId, type: 'fall', severity: 'critical', message: 'fall', timestamp: new Date() });

      const summary = await summariseStoredData(deviceId);
      assert.equal(summary.readings, 1);
      assert.equal(summary.alerts, 1);
      assert.ok(summary.deviceRecord.length > 0);

      // Delete readings & alerts only
      const del1 = await deleteDeviceData(deviceId, { includeProfile: false });
      assert.equal(del1.readings, 1);
      assert.equal(del1.alerts, 1);
      assert.equal(del1.deviceRemoved, false);

      const devStillExists = await getDevice(deviceId);
      assert.ok(devStillExists != null);

      // Delete device profile as well
      const del2 = await deleteDeviceData(deviceId, { includeProfile: true });
      assert.equal(del2.deviceRemoved, true);
      assert.equal(await getDevice(deviceId), null);
    });
  });
});
