#pragma once

#include <Arduino.h>

/// The normalized hardware snapshot sent to BLE once per second.
/// Acceleration is in g; gyroscope values are in degrees/second.
struct TelemetryData {
  uint32_t uptimeMillis = 0;

  float heartRateBpm = NAN;
  bool heartRateValid = false;
  float spo2Percent = NAN;
  bool spo2Valid = false;

  float ambientTemperatureC = NAN;
  bool ambientTemperatureValid = false;
  float humidityPercent = NAN;
  bool humidityValid = false;

  float accelerometerXG = NAN;
  float accelerometerYG = NAN;
  float accelerometerZG = NAN;
  bool accelerometerValid = false;
  float gyroscopeXDps = NAN;
  float gyroscopeYDps = NAN;
  float gyroscopeZDps = NAN;
  bool gyroscopeValid = false;

  /// Surface wetness from the rain board: 0 dry, 100 fully bridged.
  /// rainRaw carries the underlying ADC count so a bad calibration is
  /// visible rather than silently skewing the percentage.
  float rainWetnessPercent = NAN;
  int rainRaw = -1;
  bool rainValid = false;

  /// Relative air-quality index from the MQ-135, 0 clean to 100 foul, with
  /// gasRaw carrying the ADC count behind it so a bad calibration stays
  /// visible rather than silently shifting the index.
  ///
  /// Deliberately not called AQI. The MQ-135 reads one resistance driven by
  /// CO2, ammonia, NOx, benzene and smoke together, cannot separate them, and
  /// measures no particulates at all. A published AQI figure means a specific
  /// PM2.5 concentration; calling this that would invent a health number out
  /// of an uncalibrated gas mixture.
  float gasIndex = NAN;
  int gasRaw = -1;
  bool gasValid = false;

  uint8_t signalQuality = 0;
  bool fingerPresent = false;

  bool max30102Ready = false;
  bool mpu6050Ready = false;
  bool dht22Ready = false;
  bool rainReady = false;
  bool gasReady = false;
  bool oledReady = false;
};
