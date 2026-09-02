import 'dart:math' as math;

import '../../assistant/models/assistant_context.dart';
import '../models/telemetry_frame.dart';
import 'risk_engine_config.dart';
import 'safety_assessment.dart';

/// Deterministic, explainable wellness-risk engine.
///
/// Every contribution is returned as an explanation. Poor optical data gates
/// HR, SpO2, and anomaly scoring rather than being interpreted as physiology.
/// Fall evidence remains independent because high motion is expected in a fall.
class RiskEngine {
  RiskEngine({this.config = const RiskEngineConfig()});

  final RiskEngineConfig config;

  double? _restingHeartRate;
  int _baselineSamples = 0;
  TelemetryFrame? _previousFrame;
  DateTime? _evidenceSince;
  DateTime? _stateSince;
  DateTime? _recoverySince;
  DateTime? _entrySince;
  RiskLevel? _entryTarget;
  RiskLevel _state = RiskLevel.normal;
  DateTime? _impactAt;
  DateTime? _stillSince;
  DateTime? _fallCheckInOpenedAt;
  bool _fallResolved = false;

  void reset() {
    _restingHeartRate = null;
    _baselineSamples = 0;
    _previousFrame = null;
    _evidenceSince = null;
    _stateSince = null;
    _recoverySince = null;
    _entrySince = null;
    _entryTarget = null;
    _state = RiskLevel.normal;
    _impactAt = null;
    _stillSince = null;
    _fallCheckInOpenedAt = null;
    _fallResolved = false;
  }

  /// Resolves a local fall check-in only after an explicit wearer action.
  void resolveFallCheckIn() {
    _fallResolved = true;
    _fallCheckInOpenedAt = null;
  }

  SafetyAssessment assess(
    TelemetryFrame frame, {
    required TelemetryConnectivity connectivity,
    required bool isStale,
    double? anomalyScore,
  }) {
    final now = frame.timestamp;
    final trust = _assessTrust(
      frame,
      connectivity: connectivity,
      isStale: isStale,
    );
    final fallState = _advanceFallWorkflow(frame, now);
    _updateBaseline(frame, trust);

    final explanations = <RiskReason>[];
    var score = 0.0;
    var hasIndependentEvidence = false;

    if (trust.canUsePhysiology && trust.reasons.isNotEmpty) {
      explanations.add(
        RiskReason(code: 'sensor_trust', detail: trust.reasons.first),
      );
    }

    void add(String code, String detail, double contribution) {
      if (contribution <= 0) return;
      explanations.add(
        RiskReason(
          code: code,
          detail: detail,
          contribution: contribution.round(),
        ),
      );
      score += contribution;
    }

    final heatIndex = _heatIndexC(
      frame.ambientTemperatureC,
      frame.humidityPercent,
    );
    final heatContribution = _heatContribution(heatIndex);
    if (heatContribution > 0) {
      hasIndependentEvidence = true;
      add(
        'heat_exposure',
        'Heat index ${heatIndex!.toStringAsFixed(1)} C adds ${heatContribution.round()} risk points.',
        heatContribution,
      );
    }

    final activityContribution = _activityContribution(frame, trust);
    if (activityContribution > 0) {
      hasIndependentEvidence = true;
      add(
        'activity_level',
        'Light activity is present (+${activityContribution.round()}).',
        activityContribution,
      );
    }

    if (trust.canUsePhysiology) {
      final anomalyContribution = _anomalyContribution(anomalyScore);
      if (anomalyContribution > 0) {
        add(
          'anomaly_score',
          'Anomaly input ${(anomalyScore! * 100).round()}% adds ${anomalyContribution.round()} risk points.',
          anomalyContribution,
        );
      }

      final heartRateContribution = _heartRateContribution(frame);
      if (heartRateContribution != null) {
        add(
          'heart_rate_deviation',
          heartRateContribution.detail,
          heartRateContribution.value,
        );
      }

      final spo2Contribution = _spo2Contribution(frame.spo2Percent);
      if (spo2Contribution != null) {
        add('spo2_deviation', spo2Contribution.detail, spo2Contribution.value);
      }

      final physiologyEvidence =
          anomalyContribution > 0 ||
          heartRateContribution != null ||
          spo2Contribution != null;
      if (physiologyEvidence || heatContribution > 0) {
        _evidenceSince ??= now;
      } else {
        _evidenceSince = null;
      }
      final persistenceContribution = _persistenceContribution(now);
      if (persistenceContribution != null) {
        add(
          'persistence',
          'Elevated factors persisted ${_durationLabel(now.difference(_evidenceSince!))} (+${persistenceContribution.round()}).',
          persistenceContribution,
        );
      }
    } else {
      _evidenceSince = null;
      explanations.addAll(
        trust.reasons.map(
          (detail) => RiskReason(code: 'reading_unreliable', detail: detail),
        ),
      );
    }

    final trustedCriticalSpo2 =
        trust.canUsePhysiology &&
        frame.spo2Percent != null &&
        frame.spo2Percent! <= config.fusion.spo2CriticalPercent;
    if (trustedCriticalSpo2) {
      score = math.max(score, config.fusion.criticalSpo2ScoreFloor.toDouble());
      explanations.add(
        RiskReason(
          code: 'spo2_critical_floor',
          detail:
              'Trusted SpO2 ${frame.spo2Percent!.round()}% is at or below the prototype critical floor.',
          contribution: config.fusion.criticalSpo2ScoreFloor,
        ),
      );
    }

    final fallActive = fallState != FallWorkflowState.monitoring;
    if (fallActive) {
      score = 100;
      explanations.add(
        RiskReason(
          code: fallState == FallWorkflowState.escalated
              ? 'fall_no_response'
              : 'fall_check_in',
          detail: fallState == FallWorkflowState.escalated
              ? 'Possible fall check-in expired without a response.'
              : 'Possible fall detected. Check-in is active.',
          contribution: 100,
        ),
      );
    }

    final roundedScore = score.clamp(0, 100).round();
    final target = fallActive || trustedCriticalSpo2
        ? RiskLevel.critical
        : _levelForScore(roundedScore);

    // A bad PPG frame may raise neither a recovery nor a false critical. It
    // can still show independent heat risk, and a fall always remains active.
    final mayTransition =
        trust.canUsePhysiology || hasIndependentEvidence || fallActive;
    final state = _advanceState(
      target,
      roundedScore,
      now,
      mayTransition: mayTransition,
      forcedCritical: fallActive || trustedCriticalSpo2,
    );

    _previousFrame = frame;
    return SafetyAssessment(
      riskLevel: state,
      score: roundedScore,
      sensorTrust: trust,
      fallState: fallState,
      fallDetected: fallActive,
      movementAfterFall: fallActive ? _isStill(frame) : null,
      reasons: explanations
          .map((reason) => reason.code)
          .toList(growable: false),
      explanations: explanations,
      baselineHeartRate: _restingHeartRate,
      baselineReady: _baselineSamples >= config.baseline.minimumSamples,
      heatIndexC: heatIndex,
    );
  }

  SensorTrustAssessment _assessTrust(
    TelemetryFrame frame, {
    required TelemetryConnectivity connectivity,
    required bool isStale,
  }) {
    final reasons = <String>[];
    if (connectivity != TelemetryConnectivity.connected) {
      return SensorTrustAssessment.reacquiring(
        'Telemetry link is not connected.',
      );
    }
    if (isStale) {
      return SensorTrustAssessment.stale('Telemetry packets are stale.');
    }
    if (frame.contactState == ContactState.noFinger) {
      return SensorTrustAssessment.reacquiring(
        'No finger contact. Reading unreliable - reacquiring.',
      );
    }

    var score = (frame.signalQuality * 100).round();
    final missingVitals =
        frame.heartRateBpm == null || frame.spo2Percent == null;
    if (missingVitals) {
      score -= config.sensorTrust.missingVitalPenalty;
      reasons.add('One or more optical vitals are missing.');
    }
    final highMotion = _isHighMotion(frame);
    if (highMotion) {
      score -= config.sensorTrust.highMotionPenalty;
      reasons.add('High hand motion can corrupt the optical signal.');
    }
    final packetGap = _hasPacketGap(frame);
    if (packetGap) reasons.add('A packet gap requires optical reacquisition.');
    final impossibleChange = _hasImpossibleVitalChange(frame);
    if (impossibleChange) {
      score -= config.sensorTrust.impossibleChangePenalty;
      reasons.add('Vital change is too abrupt to trust as physiology.');
    }

    score = score.clamp(0, 100).toInt();
    final mustReacquire =
        frame.signalQuality < config.sensorTrust.reacquireQuality ||
        highMotion ||
        packetGap ||
        impossibleChange ||
        (frame.heartRateBpm == null && frame.spo2Percent == null) ||
        score < config.sensorTrust.minimumTrustForPhysiology;
    if (mustReacquire) {
      return SensorTrustAssessment(
        state: SensorTrustState.reacquiring,
        score: score,
        reasons: reasons.isEmpty
            ? const ['Reading unreliable - reacquiring.']
            : reasons,
      );
    }
    if (score < (config.sensorTrust.reliableQuality * 100).round()) {
      return SensorTrustAssessment(
        state: SensorTrustState.degraded,
        score: score,
        reasons: reasons.isEmpty
            ? const ['Optical signal is usable but degraded.']
            : reasons,
      );
    }
    return SensorTrustAssessment(
      state: SensorTrustState.reliable,
      score: score,
      reasons: reasons.isEmpty ? const ['Reliable sensor signal.'] : reasons,
    );
  }

  void _updateBaseline(TelemetryFrame frame, SensorTrustAssessment trust) {
    if (!trust.canUsePhysiology || !_isAtRest(frame)) return;
    final heartRate = frame.heartRateBpm;
    if (heartRate == null ||
        heartRate < config.baseline.minimumHeartRate ||
        heartRate > config.baseline.maximumHeartRate) {
      return;
    }
    final baseline = _restingHeartRate;
    if (baseline != null &&
        _baselineSamples >= config.baseline.minimumSamples &&
        heartRate > baseline + config.baseline.freezeAboveBaselineBpm) {
      return;
    }
    _baselineSamples++;
    _restingHeartRate = baseline == null
        ? heartRate
        : baseline * (1 - config.baseline.ewmaAlpha) +
              heartRate * config.baseline.ewmaAlpha;
  }

  bool _isAtRest(TelemetryFrame frame) {
    final acceleration = frame.accelerometerMagnitude;
    final gyro = _gyroMagnitude(frame);
    return acceleration != null &&
        (acceleration - 1).abs() <= config.baseline.restAccelerationDeltaG &&
        (gyro == null || gyro <= config.baseline.restGyroscopeDps);
  }

  bool _isHighMotion(TelemetryFrame frame) {
    final acceleration = frame.accelerometerMagnitude;
    final gyro = _gyroMagnitude(frame);
    return (acceleration != null &&
            (acceleration - 1).abs() >=
                config.sensorTrust.highMotionAccelerationDeltaG) ||
        (gyro != null && gyro >= config.sensorTrust.highMotionGyroscopeDps);
  }

  bool _hasPacketGap(TelemetryFrame frame) {
    final previous = _previousFrame;
    return previous != null &&
        frame.timestamp.difference(previous.timestamp).abs() >
            config.sensorTrust.packetGap;
  }

  bool _hasImpossibleVitalChange(TelemetryFrame frame) {
    final previous = _previousFrame;
    if (previous == null) return false;
    final elapsedMs = frame.timestamp
        .difference(previous.timestamp)
        .inMilliseconds;
    if (elapsedMs <= 0 ||
        elapsedMs > config.sensorTrust.packetGap.inMilliseconds) {
      return false;
    }
    final seconds = elapsedMs / 1000;
    final hrChanged =
        frame.heartRateBpm != null &&
        previous.heartRateBpm != null &&
        (frame.heartRateBpm! - previous.heartRateBpm!).abs() / seconds >
            config.sensorTrust.maxHeartRateChangePerSecond;
    final spo2Changed =
        frame.spo2Percent != null &&
        previous.spo2Percent != null &&
        (frame.spo2Percent! - previous.spo2Percent!).abs() / seconds >
            config.sensorTrust.maxSpo2ChangePerSecond;
    return hrChanged || spo2Changed;
  }

  double _anomalyContribution(double? anomalyScore) {
    if (anomalyScore == null) return 0;
    return (anomalyScore.clamp(0, 1) * config.fusion.anomalyWeight).toDouble();
  }

  _Contribution? _heartRateContribution(TelemetryFrame frame) {
    final heartRate = frame.heartRateBpm;
    final baseline = _restingHeartRate;
    if (heartRate == null || baseline == null) return null;
    final delta = heartRate - baseline;
    final value =
        ((delta.abs() / config.fusion.heartRateDeviationForFullScoreBpm).clamp(
                  0,
                  1,
                ) *
                config.fusion.heartRateDeviationWeight)
            .toDouble();
    if (value < config.fusion.minimumReportableContribution) return null;
    final direction = delta >= 0 ? 'above' : 'below';
    return _Contribution(
      value,
      'HR ${delta >= 0 ? '+' : ''}${delta.round()} bpm $direction baseline ${baseline.round()} bpm (+${value.round()}).',
    );
  }

  _Contribution? _spo2Contribution(double? spo2) {
    if (spo2 == null || spo2 >= config.fusion.spo2NormalPercent) return null;
    final range =
        config.fusion.spo2NormalPercent - config.fusion.spo2CriticalPercent;
    final value =
        (((config.fusion.spo2NormalPercent - spo2) / range).clamp(0, 1) *
                config.fusion.spo2DeviationWeight)
            .toDouble();
    return _Contribution(
      value,
      'SpO2 ${spo2.round()}% is ${(config.fusion.spo2NormalPercent - spo2).round()} points below ${config.fusion.spo2NormalPercent.round()}% (+${value.round()}).',
    );
  }

  double _heatContribution(double? heatIndex) {
    if (heatIndex == null || heatIndex <= config.fusion.heatStartC) return 0;
    final range = config.fusion.heatFullScoreC - config.fusion.heatStartC;
    return (((heatIndex - config.fusion.heatStartC) / range).clamp(0, 1) *
            config.fusion.heatExposureWeight)
        .toDouble();
  }

  double _activityContribution(
    TelemetryFrame frame,
    SensorTrustAssessment trust,
  ) {
    if (!trust.canUsePhysiology || _isHighMotion(frame)) return 0;
    final acceleration = frame.accelerometerMagnitude;
    final gyro = _gyroMagnitude(frame);
    final active =
        (acceleration != null &&
            (acceleration - 1).abs() >=
                config.fusion.lightActivityAccelerationDeltaG) ||
        (gyro != null && gyro >= config.fusion.lightActivityGyroscopeDps);
    return active ? config.fusion.activityWeight.toDouble() : 0;
  }

  double? _persistenceContribution(DateTime now) {
    final since = _evidenceSince;
    if (since == null) return null;
    final elapsed = now.difference(since);
    if (elapsed <= Duration.zero) return null;
    return ((elapsed.inMilliseconds /
                    config.fusion.persistenceFullScore.inMilliseconds)
                .clamp(0, 1) *
            config.fusion.persistenceWeight)
        .toDouble();
  }

  FallWorkflowState _advanceFallWorkflow(TelemetryFrame frame, DateTime now) {
    if (_fallResolved) return FallWorkflowState.monitoring;
    if (frame.fallDetected == true) {
      _fallCheckInOpenedAt ??= now;
    } else if (_fallCheckInOpenedAt == null) {
      final magnitude = frame.accelerometerMagnitude;
      if (magnitude != null && magnitude >= config.fall.impactAccelerationG) {
        _impactAt = now;
        _stillSince = null;
      }
      if (_impactAt != null) {
        if (now.difference(_impactAt!) > config.fall.verificationWindow) {
          _impactAt = null;
          _stillSince = null;
          return FallWorkflowState.monitoring;
        }
        if (_isStill(frame)) {
          _stillSince ??= now;
          if (now.difference(_stillSince!) >= config.fall.stillnessDuration) {
            _fallCheckInOpenedAt = now;
          }
        } else {
          _stillSince = null;
        }
      }
    }

    final openedAt = _fallCheckInOpenedAt;
    if (openedAt == null) return FallWorkflowState.monitoring;
    if (now.difference(openedAt) >= config.fall.checkInWindow) {
      return FallWorkflowState.escalated;
    }
    return FallWorkflowState.checkIn;
  }

  bool _isStill(TelemetryFrame frame) {
    final magnitude = frame.accelerometerMagnitude;
    return magnitude != null &&
        (magnitude - 1).abs() <= config.fall.stillnessBandG;
  }

  RiskLevel _advanceState(
    RiskLevel target,
    int score,
    DateTime now, {
    required bool mayTransition,
    required bool forcedCritical,
  }) {
    _stateSince ??= now;
    if (forcedCritical) {
      _state = RiskLevel.critical;
      _stateSince = now;
      _recoverySince = null;
      _entrySince = null;
      _entryTarget = null;
      return _state;
    }
    if (!mayTransition) return _state;

    if (_rank(target) > _rank(_state)) {
      if (_entryTarget != target) {
        _entryTarget = target;
        _entrySince = now;
      }
      if (now.difference(_entrySince!) < _entryPersistence(target)) {
        return _state;
      }
      _state = target;
      _stateSince = now;
      _recoverySince = null;
      _entrySince = null;
      _entryTarget = null;
      return _state;
    }
    _entrySince = null;
    _entryTarget = null;
    if (_rank(target) >= _rank(_state)) {
      _recoverySince = null;
      return _state;
    }
    if (score > _exitThreshold(_state)) {
      _recoverySince = null;
      return _state;
    }
    _recoverySince ??= now;
    if (now.difference(_recoverySince!) >= _recoveryWindow(_state) &&
        now.difference(_stateSince!) >= _minimumDwell(_state)) {
      _state = _stepDown(_state);
      _stateSince = now;
      _recoverySince = null;
    }
    return _state;
  }

  RiskLevel _levelForScore(int score) {
    if (score >= config.stateMachine.criticalEnter) return RiskLevel.critical;
    if (score >= config.stateMachine.warningEnter) return RiskLevel.warning;
    if (score >= config.stateMachine.watchEnter) return RiskLevel.watch;
    return RiskLevel.normal;
  }

  int _exitThreshold(RiskLevel state) => switch (state) {
    RiskLevel.critical => config.stateMachine.criticalExit,
    RiskLevel.warning => config.stateMachine.warningExit,
    RiskLevel.watch => config.stateMachine.watchExit,
    RiskLevel.normal || RiskLevel.notComputed => 0,
  };

  Duration _recoveryWindow(RiskLevel state) => switch (state) {
    RiskLevel.critical => config.stateMachine.criticalRecovery,
    RiskLevel.warning => config.stateMachine.warningRecovery,
    RiskLevel.watch => config.stateMachine.watchRecovery,
    RiskLevel.normal || RiskLevel.notComputed => Duration.zero,
  };

  Duration _entryPersistence(RiskLevel state) => switch (state) {
    RiskLevel.critical => config.stateMachine.criticalEntryPersistence,
    RiskLevel.warning => config.stateMachine.warningEntryPersistence,
    RiskLevel.watch => config.stateMachine.watchEntryPersistence,
    RiskLevel.normal || RiskLevel.notComputed => Duration.zero,
  };

  Duration _minimumDwell(RiskLevel state) => switch (state) {
    RiskLevel.critical => config.stateMachine.criticalMinimumDwell,
    RiskLevel.warning => config.stateMachine.warningMinimumDwell,
    RiskLevel.watch => config.stateMachine.watchMinimumDwell,
    RiskLevel.normal || RiskLevel.notComputed => Duration.zero,
  };

  RiskLevel _stepDown(RiskLevel state) => switch (state) {
    RiskLevel.critical => RiskLevel.warning,
    RiskLevel.warning => RiskLevel.watch,
    RiskLevel.watch => RiskLevel.normal,
    RiskLevel.normal || RiskLevel.notComputed => RiskLevel.normal,
  };

  int _rank(RiskLevel level) => switch (level) {
    RiskLevel.notComputed => -1,
    RiskLevel.normal => 0,
    RiskLevel.watch => 1,
    RiskLevel.warning => 2,
    RiskLevel.critical => 3,
  };

  double? _gyroMagnitude(TelemetryFrame frame) {
    final x = frame.gyroscopeX;
    final y = frame.gyroscopeY;
    final z = frame.gyroscopeZ;
    if (x == null || y == null || z == null) return null;
    return math.sqrt(x * x + y * y + z * z);
  }

  double? _heatIndexC(double? temperatureC, double? humidity) {
    if (temperatureC == null || humidity == null) return null;
    final fahrenheit = temperatureC * 9 / 5 + 32;
    final rh = humidity.clamp(0, 100).toDouble();
    final simple =
        0.5 * (fahrenheit + 61 + (fahrenheit - 68) * 1.2 + rh * 0.094);
    if ((simple + fahrenheit) / 2 < 80) {
      return ((simple + fahrenheit) / 2 - 32) * 5 / 9;
    }

    var heatIndex =
        -42.379 +
        2.04901523 * fahrenheit +
        10.14333127 * rh -
        0.22475541 * fahrenheit * rh -
        0.00683783 * fahrenheit * fahrenheit -
        0.05481717 * rh * rh +
        0.00122874 * fahrenheit * fahrenheit * rh +
        0.00085282 * fahrenheit * rh * rh -
        0.00000199 * fahrenheit * fahrenheit * rh * rh;
    if (rh < 13 && fahrenheit >= 80 && fahrenheit <= 112) {
      heatIndex -=
          (13 - rh) / 4 * math.sqrt((17 - (fahrenheit - 95).abs()) / 17);
    } else if (rh > 85 && fahrenheit >= 80 && fahrenheit <= 87) {
      heatIndex += (rh - 85) / 10 * (87 - fahrenheit) / 5;
    }
    return ((heatIndex - 32) * 5 / 9).clamp(-50, 58).toDouble();
  }

  String _durationLabel(Duration duration) {
    if (duration.inMinutes >= 1) return '${duration.inMinutes} min';
    return '${duration.inSeconds} s';
  }
}

class _Contribution {
  const _Contribution(this.value, this.detail);

  final double value;
  final String detail;
}
