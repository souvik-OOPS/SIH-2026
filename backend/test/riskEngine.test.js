import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { assessRisk, RiskLevel } from '../src/services/riskEngine.js';

describe('riskEngine Service Tests', () => {
  it('returns UNKNOWN with low confidence when no vitals or alerts are present', () => {
    const risk = assessRisk({ reading: {}, alerts: [] });
    assert.equal(risk.level, RiskLevel.UNKNOWN);
    assert.equal(risk.confidence, 'low');
    assert.ok(risk.factors.some((f) => f.code === 'no_data'));
  });

  it('reports NORMAL with high confidence for healthy vitals and ready baseline', () => {
    const risk = assessRisk({
      reading: { heartRate: 72, spo2: 98, signalOk: true },
      derived: { baselineReady: true, heatBand: 'safe' },
      alerts: [],
    });
    assert.equal(risk.level, RiskLevel.NORMAL);
    assert.equal(risk.confidence, 'high');
  });

  it('never lowers risk below what an alert decided (floor preservation)', () => {
    const criticalAlert = {
      type: 'hypoxia',
      severity: 'critical',
      message: 'Blood oxygen critically low',
    };
    const risk = assessRisk({
      reading: { heartRate: 72, spo2: 85, signalOk: true },
      alerts: [criticalAlert],
    });
    assert.equal(risk.level, RiskLevel.CRITICAL);
  });

  it('marks confidence as low if signalOk is false', () => {
    const risk = assessRisk({
      reading: { heartRate: 140, spo2: 98, signalOk: false },
      alerts: [{ type: 'tachycardia', severity: 'warning', message: 'High HR' }],
    });
    assert.equal(risk.level, RiskLevel.WARNING);
    assert.equal(risk.confidence, 'low');
    assert.ok(risk.summary.includes('Readings may be unreliable'));
  });

  it('escalates to CRITICAL on unconfirmed or escalated fall', () => {
    const riskEscalated = assessRisk({
      reading: { heartRate: 75, spo2: 98 },
      nonResponse: { state: 'escalated' },
    });
    assert.equal(riskEscalated.level, RiskLevel.CRITICAL);

    const riskAwaiting = assessRisk({
      reading: { heartRate: 75, spo2: 98 },
      nonResponse: { state: 'awaiting' },
    });
    assert.equal(riskAwaiting.level, RiskLevel.CRITICAL);
  });

  it('adds heat_environment factor for dangerous heat conditions', () => {
    const riskDanger = assessRisk({
      reading: { heartRate: 75, spo2: 98 },
      derived: { heatBand: 'danger', heatBandLabel: 'Danger' },
    });
    assert.equal(riskDanger.level, RiskLevel.WARNING);
    assert.ok(riskDanger.factors.some((f) => f.code === 'heat_environment'));

    // Test extreme_danger band
    const riskExtreme = assessRisk({
      reading: { heartRate: 75, spo2: 98 },
      derived: { heatBand: 'extreme_danger', heatBandLabel: 'Extreme danger' },
    });
    // This should flag heat_environment as WARNING
    assert.equal(riskExtreme.level, RiskLevel.WARNING);
    assert.ok(riskExtreme.factors.some((f) => f.code === 'heat_environment'));
  });

  it('adds disaster_context factor for severe local alerts', () => {
    const risk = assessRisk({
      reading: { heartRate: 75, spo2: 98 },
      disaster: { highestSeverity: 'severe', count: 2 },
    });
    assert.equal(risk.level, RiskLevel.CAUTION);
    assert.ok(risk.factors.some((f) => f.code === 'disaster_context'));
  });
});
