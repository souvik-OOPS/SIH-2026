#pragma once

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
  void scanI2cBus();
  void beginMax30102();
  void beginMpu6050();
  float readGravityMagnitude(uint8_t address);
  void updatePpg();
  void updateMotion();
  void updateDht22();
  void updateRain();
  void updateSignalQuality(uint32_t irValue);

  MAX30105 _max30102;
  DHT _dht{DHT_DATA_PIN, DHT22};

  bool _max30102Ready = false;
  bool _mpu6050Ready = false;
  uint8_t _mpu6050Address = 0;
  bool _dht22Ready = false;

  uint32_t _lastPpgReadMs = 0;
  uint32_t _lastIrLogMs = 0;
  uint32_t _lastDhtReadMs = 0;
  uint32_t _lastRainReadMs = 0;
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

  /// Raw 12-bit ADC count, kept alongside the percentage so a miscalibrated
  /// board can be diagnosed from telemetry instead of by guesswork.
  int _rainRaw = -1;
  float _rainWetnessPercent = NAN;
  bool _rainReady = false;
};
