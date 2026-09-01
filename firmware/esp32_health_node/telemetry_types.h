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

  uint8_t signalQuality = 0;
  bool fingerPresent = false;

  bool max30102Ready = false;
  bool mpu6050Ready = false;
  bool dht22Ready = false;
  bool oledReady = false;
};
