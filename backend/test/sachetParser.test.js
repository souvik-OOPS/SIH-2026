import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseIstTimestamp,
  normaliseSeverity,
  parseCentroid,
  distanceKm,
  classifyHazard,
  parseAlert,
  parseSachetPayload,
} from '../src/services/disaster/sachetParser.js';
import { Severity } from '../src/services/disaster/types.js';

describe('sachetParser Service Tests', () => {
  describe('parseIstTimestamp', () => {
    it('parses valid IST timestamp string', () => {
      // "Wed Sep 02 19:43:00 IST 2026"
      const d = parseIstTimestamp('Wed Sep 02 19:43:00 IST 2026');
      assert.ok(d instanceof Date);
      assert.ok(!Number.isNaN(d.getTime()));
      // 19:43 IST is 14:13 UTC
      assert.equal(d.getUTCHours(), 14);
      assert.equal(d.getUTCMinutes(), 13);
      assert.equal(d.getUTCDate(), 2);
      assert.equal(d.getUTCMonth(), 8); // Sep is 8 (0-indexed)
      assert.equal(d.getUTCFullYear(), 2026);
    });

    it('rejects non-IST timezones or malformed strings', () => {
      assert.equal(parseIstTimestamp('Wed Sep 02 19:43:00 UTC 2026'), null);
      assert.equal(parseIstTimestamp('2026-09-02T19:43:00Z'), null);
      assert.equal(parseIstTimestamp('invalid-date'), null);
      assert.equal(parseIstTimestamp(null), null);
    });
  });

  describe('normaliseSeverity', () => {
    it('prioritizes severityColor', () => {
      assert.equal(normaliseSeverity({ severityColor: 'Red', severity: 'Watch' }), Severity.SEVERE);
      assert.equal(normaliseSeverity({ severityColor: 'Orange', severity: 'Info' }), Severity.MODERATE);
      assert.equal(normaliseSeverity({ severityColor: 'Yellow', severity: 'None' }), Severity.MINOR);
    });

    it('falls back to severity string if severityColor is missing', () => {
      assert.equal(normaliseSeverity({ severity: 'Warning' }), Severity.SEVERE);
      assert.equal(normaliseSeverity({ severity: 'Alert' }), Severity.MODERATE);
      assert.equal(normaliseSeverity({ severity: 'Watch' }), Severity.MINOR);
      assert.equal(normaliseSeverity({ severity: 'Unknown' }), Severity.UNKNOWN);
    });
  });

  describe('parseCentroid', () => {
    it('parses longitude,latitude string correctly', () => {
      const parsed = parseCentroid('77.5946,12.9716');
      assert.deepEqual(parsed, { lon: 77.5946, lat: 12.9716 });
    });

    it('rejects invalid or out of bounds coordinates', () => {
      assert.equal(parseCentroid(null), null);
      assert.equal(parseCentroid('invalid'), null);
      assert.equal(parseCentroid('200,50'), null); // lon > 180
      assert.equal(parseCentroid('77,95'), null);  // lat > 90
    });
  });

  describe('distanceKm', () => {
    it('calculates great circle distance accurately', () => {
      // Bangalore (12.9716, 77.5946) to Chennai (13.0827, 80.2707) is ~290 km
      const d = distanceKm({ lat: 12.9716, lon: 77.5946 }, { lat: 13.0827, lon: 80.2707 });
      assert.ok(d > 280 && d < 300);
    });
  });

  describe('classifyHazard', () => {
    it('classifies various disaster types', () => {
      assert.equal(classifyHazard('Heat Wave Warning'), 'heat');
      assert.equal(classifyHazard('Severe Flood Alert'), 'flood');
      assert.equal(classifyHazard('Thunderstorm with lightning'), 'storm');
      assert.equal(classifyHazard('Tropical Cyclone'), 'cyclone');
      assert.equal(classifyHazard('Dense Fog / Cold wave'), 'cold');
      assert.equal(classifyHazard('Landslide'), 'landslide');
      assert.equal(classifyHazard('Earthquake'), 'earthquake');
      assert.equal(classifyHazard('Unknown Type'), 'other');
      assert.equal(classifyHazard(''), 'unknown');
    });
  });

  describe('parseSachetPayload', () => {
    it('parses full array of alerts and applies filters', () => {
      const now = new Date('2026-09-02T15:00:00Z');
      const payload = [
        {
          identifier: 'alert-1',
          effective_start_time: 'Wed Sep 02 19:00:00 IST 2026', // 13:30 UTC
          effective_end_time: 'Wed Sep 02 22:00:00 IST 2026',   // 16:30 UTC (active)
          disaster_type: 'Heat Wave',
          severity_color: 'Red',
          warning_message: 'Extreme heat expected',
          actual_lang: 'en',
          centroid: '77.5,12.9',
        },
        {
          identifier: 'alert-2',
          effective_start_time: 'Wed Sep 02 10:00:00 IST 2026',
          effective_end_time: 'Wed Sep 02 12:00:00 IST 2026',   // Expired
          disaster_type: 'Thunderstorm',
          severity_color: 'Yellow',
          warning_message: 'Rain expected',
          actual_lang: 'en',
        },
        {
          identifier: 'alert-3',
          effective_start_time: 'Wed Sep 02 19:00:00 IST 2026',
          effective_end_time: 'Wed Sep 02 22:00:00 IST 2026',
          disaster_type: 'Flood',
          severity_color: 'Orange',
          warning_message: 'Flood warning',
          actual_lang: 'hi', // Hindi
        },
      ];

      const result = parseSachetPayload(payload, { now, language: 'en', activeOnly: true });
      assert.equal(result.total, 3);
      assert.equal(result.alerts.length, 1);
      assert.equal(result.alerts[0].id, 'alert-1');
      assert.equal(result.alerts[0].hazard, 'heat');
      assert.equal(result.alerts[0].severity, Severity.SEVERE);
    });
  });
});
