#pragma once

#include <Adafruit_MPU6050.h>
#include <DHT.h>
#include <MAX30105.h>

#include "config.h"
#include "telemetry_types.h"

class SensorNode {
 public:
  void begin();
  void update();
  TelemetryData snapshot(bool oledReady) const;

 private:
  void beginMax30102();
  void beginMpu6050();
  void updatePpg();
  void updateMotion();
  void updateDht22();
  void updateSignalQuality(uint32_t irValue);

  MAX30105 _max30102;
  DHT _dht{DHT_DATA_PIN, DHT22};
  Adafruit_MPU6050 _mpu;

  bool _max30102Ready = false;
  bool _mpu6050Ready = false;
  bool _dht22Ready = false;

  uint32_t _lastPpgReadMs = 0;
  uint32_t _lastDhtReadMs = 0;
  uint32_t _lastMotionReadMs = 0;
  uint32_t _lastBeatMs = 0;
  float _heartRateBpm = NAN;
  float _spo2Percent = NAN;
  bool _spo2Valid = false;
  bool _fingerPresent = false;
  uint8_t _signalQuality = 0;

  static constexpr uint8_t kSpo2BufferLength = 100;
  uint32_t _irBuffer[kSpo2BufferLength] = {0};
  uint32_t _redBuffer[kSpo2BufferLength] = {0};
  uint8_t _spo2BufferCount = 0;

  float _ambientTemperatureC = NAN;
  float _humidityPercent = NAN;
  float _accelerometerXG = NAN;
  float _accelerometerYG = NAN;
  float _accelerometerZG = NAN;
  float _gyroscopeXDps = NAN;
  float _gyroscopeYDps = NAN;
  float _gyroscopeZDps = NAN;
};
