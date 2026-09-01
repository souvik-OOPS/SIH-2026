#include "sensor_node.h"

#include <Wire.h>

#include "config.h"
#include "heartRate.h"
#include "spo2_algorithm.h"

namespace {
constexpr float kGravityMps2 = 9.80665f;
constexpr uint32_t kMotionIntervalMs = 20;
constexpr uint32_t kDhtIntervalMs = 2000;
constexpr uint32_t kFingerTimeoutMs = 5000;
constexpr uint32_t kPpgSampleIntervalMs = 1000UL / PPG_SAMPLE_RATE_HZ;
}  // namespace

void SensorNode::begin() {
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(400000);

  beginMax30102();
  beginMpu6050();

  _dht.begin();
  Serial.println(F("[sensor] DHT22 started (ambient only); presence confirmed on first valid read"));
}

void SensorNode::beginMax30102() {
  if (!_max30102.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println(F("[sensor] MAX30102 not found at expected address 0x57"));
    return;
  }

  // Red + IR mode supports heartbeat detection and the installed SparkFun /
  // Maxim reference SpO2 algorithm. Invalid optical data is emitted as null,
  // never as an invented SpO2 measurement.
  _max30102.setup(
      60,                         // LED brightness
      4,                          // sample average
      2,                          // red + IR
      PPG_SAMPLE_RATE_HZ,
      411,                        // pulse width
      4096);                      // ADC range
  _max30102Ready = true;
  Serial.println(F("[sensor] MAX30102 ready"));
}

void SensorNode::beginMpu6050() {
  if (!_mpu.begin(0x68, &Wire) && !_mpu.begin(0x69, &Wire)) {
    Serial.println(F("[sensor] MPU6050 not found at 0x68 or 0x69"));
    return;
  }

  _mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
  _mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  _mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  _mpu6050Ready = true;
  Serial.println(F("[sensor] MPU6050 ready"));
}

void SensorNode::update() {
  updatePpg();
  updateMotion();
  updateDht22();
}

void SensorNode::updatePpg() {
  if (!_max30102Ready || millis() - _lastPpgReadMs < kPpgSampleIntervalMs) {
    return;
  }
  _lastPpgReadMs = millis();

  _max30102.check();
  if (!_max30102.available()) return;

  const uint32_t ir = _max30102.getIR();
  const uint32_t red = _max30102.getRed();
  _max30102.nextSample();
  updateSignalQuality(ir);

  if (!_fingerPresent) {
    _heartRateBpm = NAN;
    _spo2Percent = NAN;
    _spo2Valid = false;
    _spo2BufferCount = 0;
    return;
  }

  _irBuffer[_spo2BufferCount] = ir;
  _redBuffer[_spo2BufferCount] = red;
  _spo2BufferCount++;
  if (_spo2BufferCount == kSpo2BufferLength) {
    int32_t algorithmSpo2 = 0;
    int8_t algorithmSpo2Valid = 0;
    int32_t algorithmHeartRate = 0;
    int8_t algorithmHeartRateValid = 0;
    maxim_heart_rate_and_oxygen_saturation(
        _irBuffer,
        kSpo2BufferLength,
        _redBuffer,
        &algorithmSpo2,
        &algorithmSpo2Valid,
        &algorithmHeartRate,
        &algorithmHeartRateValid);

    _spo2Valid = algorithmSpo2Valid && algorithmSpo2 >= 50 && algorithmSpo2 <= 100;
    _spo2Percent = _spo2Valid ? static_cast<float>(algorithmSpo2) : NAN;

    // Retain 75 samples so subsequent algorithm results update every second.
    for (uint8_t i = 0; i < 75; ++i) {
      _irBuffer[i] = _irBuffer[i + 25];
      _redBuffer[i] = _redBuffer[i + 25];
    }
    _spo2BufferCount = 75;
  }

  if (checkForBeat(ir)) {
    const uint32_t now = millis();
    if (_lastBeatMs != 0) {
      const float bpm = 60000.0f / static_cast<float>(now - _lastBeatMs);
      if (bpm >= 30.0f && bpm <= 220.0f) {
        _heartRateBpm = isnan(_heartRateBpm) ? bpm : (_heartRateBpm * 0.75f + bpm * 0.25f);
      }
    }
    _lastBeatMs = now;
  }

  if (_lastBeatMs == 0 || millis() - _lastBeatMs > kFingerTimeoutMs) {
    _heartRateBpm = NAN;
  }
}

void SensorNode::updateSignalQuality(uint32_t irValue) {
  _fingerPresent = irValue >= FINGER_IR_THRESHOLD;
  if (!_fingerPresent) {
    _signalQuality = 0;
    return;
  }

  // This is deliberately a contact-strength heuristic only. It gives the app
  // a reliable way to suppress poor optical data without claiming accuracy.
  const uint32_t usableRange = 120000UL;
  const uint32_t aboveThreshold = irValue - FINGER_IR_THRESHOLD;
  _signalQuality = static_cast<uint8_t>(
      min(100UL, (aboveThreshold * 100UL) / usableRange));
}

void SensorNode::updateMotion() {
  if (!_mpu6050Ready || millis() - _lastMotionReadMs < kMotionIntervalMs) {
    return;
  }
  _lastMotionReadMs = millis();

  sensors_event_t accel;
  sensors_event_t gyro;
  sensors_event_t temperature;
  _mpu.getEvent(&accel, &gyro, &temperature);

  _accelerometerXG = accel.acceleration.x / kGravityMps2;
  _accelerometerYG = accel.acceleration.y / kGravityMps2;
  _accelerometerZG = accel.acceleration.z / kGravityMps2;
  _gyroscopeXDps = gyro.gyro.x * RAD_TO_DEG;
  _gyroscopeYDps = gyro.gyro.y * RAD_TO_DEG;
  _gyroscopeZDps = gyro.gyro.z * RAD_TO_DEG;
}

void SensorNode::updateDht22() {
  if (millis() - _lastDhtReadMs < kDhtIntervalMs) return;
  _lastDhtReadMs = millis();

  const float humidity = _dht.readHumidity();
  const float ambientTemperature = _dht.readTemperature();
  if (isnan(humidity) || isnan(ambientTemperature)) {
    _humidityPercent = NAN;
    _ambientTemperatureC = NAN;
    Serial.println(F("[sensor] DHT22 read failed"));
    return;
  }

  if (!_dht22Ready) {
    _dht22Ready = true;
    Serial.println(F("[sensor] DHT22 ready (ambient temperature and humidity only)"));
  }
  _humidityPercent = humidity;
  _ambientTemperatureC = ambientTemperature;
}

TelemetryData SensorNode::snapshot(bool oledReady) const {
  TelemetryData data;
  data.uptimeMillis = millis();
  data.heartRateBpm = _heartRateBpm;
  data.heartRateValid = !isnan(_heartRateBpm) && _fingerPresent;
  data.spo2Percent = _spo2Percent;
  data.spo2Valid = _spo2Valid && _fingerPresent;
  data.ambientTemperatureC = _ambientTemperatureC;
  data.ambientTemperatureValid = !isnan(_ambientTemperatureC);
  data.humidityPercent = _humidityPercent;
  data.humidityValid = !isnan(_humidityPercent);
  data.accelerometerXG = _accelerometerXG;
  data.accelerometerYG = _accelerometerYG;
  data.accelerometerZG = _accelerometerZG;
  data.accelerometerValid = !isnan(_accelerometerXG) && !isnan(_accelerometerYG) && !isnan(_accelerometerZG);
  data.gyroscopeXDps = _gyroscopeXDps;
  data.gyroscopeYDps = _gyroscopeYDps;
  data.gyroscopeZDps = _gyroscopeZDps;
  data.gyroscopeValid = !isnan(_gyroscopeXDps) && !isnan(_gyroscopeYDps) && !isnan(_gyroscopeZDps);
  data.signalQuality = _signalQuality;
  data.fingerPresent = _fingerPresent;
  data.max30102Ready = _max30102Ready;
  data.mpu6050Ready = _mpu6050Ready;
  data.dht22Ready = _dht22Ready;
  data.oledReady = oledReady;
  return data;
}
