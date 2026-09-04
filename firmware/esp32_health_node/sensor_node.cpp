#include "sensor_node.h"

#include <Wire.h>

#include "config.h"
#include "heartRate.h"
#include "spo2_algorithm.h"

namespace {
constexpr uint32_t kMotionIntervalMs = 20;
constexpr uint32_t kDhtIntervalMs = 2000;
// Rain changes on a weather timescale; sampling it fast buys nothing and
// only adds ADC noise to average away.
constexpr uint32_t kRainIntervalMs = 2000;
constexpr uint8_t kRainSamples = 8;
constexpr uint32_t kFingerTimeoutMs = 5000;
constexpr uint32_t kPpgSampleIntervalMs = 1000UL / PPG_SAMPLE_RATE_HZ;

constexpr uint8_t kMpuRegisterSampleRateDivider = 0x19;
constexpr uint8_t kMpuRegisterConfig = 0x1A;
constexpr uint8_t kMpuRegisterGyroConfig = 0x1B;
constexpr uint8_t kMpuRegisterAccelerometerConfig = 0x1C;
constexpr uint8_t kMpuRegisterAccelerometerXoutHigh = 0x3B;
constexpr uint8_t kMpuRegisterPowerManagement1 = 0x6B;
constexpr uint8_t kMpuRegisterWhoAmI = 0x75;
constexpr float kMpuAccelerometerLsbPerG = 4096.0f;  // +/- 8 g
constexpr float kMpuGyroscopeLsbPerDps = 65.5f;      // +/- 500 dps

bool writeMpuRegister(uint8_t address, uint8_t registerAddress, uint8_t value) {
  Wire.beginTransmission(address);
  Wire.write(registerAddress);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool readMpuRegisters(
    uint8_t address,
    uint8_t registerAddress,
    uint8_t* values,
    size_t length) {
  Wire.beginTransmission(address);
  Wire.write(registerAddress);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(static_cast<int>(address), static_cast<int>(length)) != length) {
    return false;
  }
  for (size_t index = 0; index < length; ++index) {
    if (!Wire.available()) return false;
    values[index] = Wire.read();
  }
  return true;
}

int16_t signed16(uint8_t high, uint8_t low) {
  return static_cast<int16_t>((static_cast<uint16_t>(high) << 8) | low);
}

/// Identities we have seen on genuine and clone parts.
///
/// This is advisory only. It decides whether to print a warning, never
/// whether to use the device: a whitelist fails closed on every clone nobody
/// has catalogued yet, and the cheap GY-521 boards return all sorts of things
/// - 0x73, 0x75, 0x78 and 0x98 are all in the wild - while exposing exactly
/// the register map used below. Behaviour is the better test, so
/// beginMpu6050() proves the part by reading gravity off it instead.
bool isKnownMpuIdentity(uint8_t identity) {
  return identity == 0x68 ||  // MPU6050
      identity == 0x69 ||     // some clones echo their own bus address
      identity == 0x70 ||     // MPU6500
      identity == 0x71 ||     // MPU9250
      identity == 0x72 ||     // MPU9255 / clone
      identity == 0x73 ||     // clone
      identity == 0x75 ||     // clone
      identity == 0x78 ||     // clone
      identity == 0x98;       // clone
}

/// A stationary IMU must see one gravity. Anything far from 1 g means the
/// registers answered but the part is not really converting - a dead clone,
/// a part still asleep, or the wrong chip entirely.
constexpr float kGravityPlausibleMinG = 0.4f;
constexpr float kGravityPlausibleMaxG = 2.2f;
}  // namespace

void SensorNode::begin() {
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(400000);
  scanI2cBus();

  beginMax30102();
  beginMpu6050();

#if RAIN_ENABLED
  // 12-bit, 11 dB attenuation: the rain board swings the whole 0-3.3 V range,
  // and the default 0 dB would clip everything above roughly 1.1 V.
  analogReadResolution(12);
  analogSetPinAttenuation(RAIN_ANALOG_PIN, ADC_11db);
  Serial.println(F("[sensor] rain board on ADC1 GPIO 34"));
#endif

  _dht.begin();
  Serial.println(F("[sensor] DHT22 started (ambient only); presence confirmed on first valid read"));
}

void SensorNode::scanI2cBus() {
  Serial.printf("[i2c] scanning SDA=%d SCL=%d\n", I2C_SDA_PIN, I2C_SCL_PIN);

  bool foundDevice = false;
  for (uint8_t address = 1; address < 127; ++address) {
    Wire.beginTransmission(address);
    if (Wire.endTransmission() != 0) continue;

    Serial.printf("[i2c] found 0x%02X\n", address);
    foundDevice = true;
  }

  if (!foundDevice) Serial.println(F("[i2c] no devices found"));
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

/// Reads the accelerometer once and reports the magnitude in g.
/// Returns NAN if the registers cannot be read.
float SensorNode::readGravityMagnitude(uint8_t address) {
  uint8_t raw[6] = {0};
  if (!readMpuRegisters(address, kMpuRegisterAccelerometerXoutHigh, raw, sizeof(raw))) {
    return NAN;
  }
  const float x = signed16(raw[0], raw[1]) / kMpuAccelerometerLsbPerG;
  const float y = signed16(raw[2], raw[3]) / kMpuAccelerometerLsbPerG;
  const float z = signed16(raw[4], raw[5]) / kMpuAccelerometerLsbPerG;
  return sqrtf(x * x + y * y + z * z);
}

void SensorNode::beginMpu6050() {
  for (const uint8_t address : {0x68, 0x69}) {
    // Does anything answer here at all? Separating this from the WHO_AM_I read
    // distinguishes "nothing on the bus" from "something that will not
    // identify itself", which are different wiring faults.
    Wire.beginTransmission(address);
    if (Wire.endTransmission() != 0) continue;

    uint8_t identity = 0xFF;
    const bool identityRead = readMpuRegisters(address, kMpuRegisterWhoAmI, &identity, 1);
    if (!identityRead) {
      Serial.printf("[sensor] IMU at 0x%02X answered but WHO_AM_I could not be read\n", address);
      continue;
    }

    // Always print it. The previous build rejected unlisted identities in
    // silence, which left a working clone indistinguishable from an unplugged
    // module at the serial monitor.
    Serial.printf("[sensor] IMU at 0x%02X WHO_AM_I=0x%02X%s\n", address, identity,
                  isKnownMpuIdentity(identity) ? "" : "  (not in the known table)");

    // Reset first. Several clones come up in a state where the configuration
    // writes below are accepted but ignored until the part has been reset.
    if (!writeMpuRegister(address, kMpuRegisterPowerManagement1, 0x80)) continue;
    delay(100);

    if (!writeMpuRegister(address, kMpuRegisterPowerManagement1, 0x01) ||
        !writeMpuRegister(address, kMpuRegisterConfig, 0x03) ||
        !writeMpuRegister(address, kMpuRegisterSampleRateDivider, 0x04) ||
        !writeMpuRegister(address, kMpuRegisterGyroConfig, 0x08) ||
        !writeMpuRegister(address, kMpuRegisterAccelerometerConfig, 0x10)) {
      Serial.printf("[sensor] IMU at 0x%02X did not accept configuration\n", address);
      continue;
    }
    delay(50);  // let the first conversion complete before trusting a read

    // The real acceptance test. An ID byte only says what a part claims to be;
    // one gravity says it is actually converting.
    const float magnitude = readGravityMagnitude(address);
    if (isnan(magnitude) ||
        magnitude < kGravityPlausibleMinG ||
        magnitude > kGravityPlausibleMaxG) {
      Serial.printf(
          "[sensor] IMU at 0x%02X configured but reads %.2f g, expected about 1 g - "
          "check wiring and that it is still\n",
          address, magnitude);
      continue;
    }

    _mpu6050Address = address;
    _mpu6050Ready = true;
    Serial.printf("[sensor] IMU ready at 0x%02X (WHO_AM_I=0x%02X, %.2f g at rest)\n",
                  address, identity, magnitude);
    return;
  }

  Serial.println(F("[sensor] no usable IMU at 0x68 or 0x69 - check SDA/SCL, 3V3 and GND"));
}

void SensorNode::update() {
  updatePpg();
  updateMotion();
  updateDht22();
  updateRain();
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

  uint8_t rawValues[14] = {0};
  if (!readMpuRegisters(
          _mpu6050Address,
          kMpuRegisterAccelerometerXoutHigh,
          rawValues,
          sizeof(rawValues))) {
    return;
  }

  _accelerometerXG = signed16(rawValues[0], rawValues[1]) / kMpuAccelerometerLsbPerG;
  _accelerometerYG = signed16(rawValues[2], rawValues[3]) / kMpuAccelerometerLsbPerG;
  _accelerometerZG = signed16(rawValues[4], rawValues[5]) / kMpuAccelerometerLsbPerG;
  _gyroscopeXDps = signed16(rawValues[8], rawValues[9]) / kMpuGyroscopeLsbPerDps;
  _gyroscopeYDps = signed16(rawValues[10], rawValues[11]) / kMpuGyroscopeLsbPerDps;
  _gyroscopeZDps = signed16(rawValues[12], rawValues[13]) / kMpuGyroscopeLsbPerDps;
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

/// Reads the rain board on ADC1.
///
/// The ESP32 ADC is noisy and not especially linear, so this averages a short
/// burst rather than trusting one conversion. The board pulls toward ground as
/// water bridges its traces, so the count is inverted into "wetness".
///
/// A board that is simply unplugged floats rather than reading a clean zero,
/// which is why the raw count is published too: a constant mid-scale value
/// with no water on the board means a disconnected sensor, not drizzle.
void SensorNode::updateRain() {
#if RAIN_ENABLED
  if (millis() - _lastRainReadMs < kRainIntervalMs) return;
  _lastRainReadMs = millis();

  uint32_t total = 0;
  for (uint8_t i = 0; i < kRainSamples; ++i) {
    total += analogRead(RAIN_ANALOG_PIN);
    delayMicroseconds(200);
  }
  const int raw = static_cast<int>(total / kRainSamples);
  _rainRaw = raw;

  const float span = static_cast<float>(RAIN_DRY_COUNT - RAIN_WET_COUNT);
  if (span <= 0.0f) {
    _rainWetnessPercent = NAN;
    return;
  }
  float pct = (static_cast<float>(RAIN_DRY_COUNT - raw) / span) * 100.0f;
  if (pct < 0.0f) pct = 0.0f;
  if (pct > 100.0f) pct = 100.0f;
  _rainWetnessPercent = pct;

  if (!_rainReady) {
    _rainReady = true;
    Serial.print(F("[sensor] rain board reading (raw "));
    Serial.print(raw);
    Serial.println(F(") - calibrate RAIN_DRY_COUNT dry and RAIN_WET_COUNT wet"));
  }
#endif
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
  data.rainWetnessPercent = _rainWetnessPercent;
  data.rainRaw = _rainRaw;
  data.rainValid = _rainReady && !isnan(_rainWetnessPercent);
  data.rainReady = _rainReady;
  data.signalQuality = _signalQuality;
  data.fingerPresent = _fingerPresent;
  data.max30102Ready = _max30102Ready;
  data.mpu6050Ready = _mpu6050Ready;
  data.dht22Ready = _dht22Ready;
  data.oledReady = oledReady;
  return data;
}
