#include "sensor_node.h"

#include <Wire.h>

#include "config.h"
#include "heartRate.h"
#include "spo2_algorithm.h"

namespace {
constexpr uint32_t kMotionIntervalMs = 20;
/// How often to retry a missing IMU. Long enough not to stall the telemetry
/// loop on a bus that has nothing on it, short enough that reseating a wire
/// shows up while a hand is still on the board.
constexpr uint32_t kImuProbeIntervalMs = 5000;
/// Gas changes on a room timescale, and each read averages several
/// conversions, so there is nothing to gain from sampling it quickly.
constexpr uint32_t kGasIntervalMs = 2000;
constexpr uint8_t kGasSamples = 8;
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
// Scale factors are read back from the part rather than assumed.
//
// These were constants matching the ranges beginMpu6050() asks for. When a
// configuration write silently failed - as it did repeatedly on this wiring -
// the chip stayed at its power-on default of +/- 2 g while the maths kept
// dividing by the +/- 8 g factor, and a stationary board reported 4.17 g of
// gravity. Wrong by exactly the ratio of the two ranges, which is the
// signature of trusting a write instead of checking it.
constexpr float kMpuAccelerometerLsbPerG = 4096.0f;  // +/- 8 g, the default ask
constexpr float kMpuGyroscopeLsbPerDps = 65.5f;      // +/- 500 dps, the default ask

/// LSB per g for the AFS_SEL bits actually present in ACCEL_CONFIG.
float accelerometerLsbPerG(uint8_t accelConfig) {
  switch ((accelConfig >> 3) & 0x03) {
    case 0: return 16384.0f;  // +/- 2 g
    case 1: return 8192.0f;   // +/- 4 g
    case 2: return 4096.0f;   // +/- 8 g
    default: return 2048.0f;  // +/- 16 g
  }
}

/// LSB per degree/second for the FS_SEL bits actually present in GYRO_CONFIG.
float gyroscopeLsbPerDps(uint8_t gyroConfig) {
  switch ((gyroConfig >> 3) & 0x03) {
    case 0: return 131.0f;   // +/- 250 dps
    case 1: return 65.5f;    // +/- 500 dps
    case 2: return 32.8f;    // +/- 1000 dps
    default: return 16.4f;   // +/- 2000 dps
  }
}

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
  // 100 kHz, not 400 kHz.
  //
  // The MPU6050 answers WHO_AM_I and then fails partway through configuration,
  // over and over - "answered but WHO_AM_I could not be read" alternating with
  // a clean read of 0x70. A chip that is absent does not answer at all, and one
  // that is present and healthy does not stop halfway; that pattern is marginal
  // signalling. Four devices on breadboard jumpers put enough capacitance on
  // SDA and SCL that fast mode's 300 ns rise-time budget is not met, and the
  // longest wire fails first.
  //
  // Standard mode allows 1000 ns, so the same wiring has over three times the
  // margin. Nothing on this bus needs the speed: the OLED redraws once a
  // second, the IMU is read at 50 Hz, and the MAX30102's FIFO is drained in
  // small bursts.
  Wire.setClock(100000);
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

#if MQ135_ENABLED
  analogReadResolution(12);
  analogSetPinAttenuation(MQ135_ANALOG_PIN, ADC_11db);
  Serial.printf(
      "[sensor] MQ-135 gas sensor on ADC1 GPIO %d, %lus warm-up (relative"
      " index, not a calibrated AQI)\n",
      (int)MQ135_ANALOG_PIN, (unsigned long)(MQ135_WARMUP_MS / 1000));
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
  // I2C_SPEED_STANDARD to match the bus clock set in begin(). Passing
  // I2C_SPEED_FAST here would put the shared bus back to 400 kHz behind the
  // deliberate choice above.
  if (!_max30102.begin(Wire, I2C_SPEED_STANDARD)) {
    Serial.println(F("[sensor] MAX30102 not found at expected address 0x57"));
    return;
  }

  // Red + IR mode supports heartbeat detection and the installed SparkFun /
  // Maxim reference SpO2 algorithm. Invalid optical data is emitted as null,
  // never as an invented SpO2 measurement.
  //
  // Two things here were wrong and both starved the algorithm:
  //
  // Brightness was 60 of 255, roughly 6 mA of drive. Through a fingertip that
  // returns an IR count well under the 50000 contact threshold, so a finger
  // that is genuinely present never registers and heart rate stays null. The
  // higher current costs battery but is what makes contact detectable.
  //
  // The FIFO averages every MAX30102_SAMPLE_AVERAGE conversions, so its output
  // rate is the sample rate divided by that average. At 25 Hz with 4x
  // averaging the FIFO produced about 6 samples a second while the read loop
  // asked for 25, so the 100-sample SpO2 buffer took 16 seconds to fill
  // instead of 4. Sampling at 100 Hz makes the post-average output 25 Hz,
  // which is what the read loop and the Maxim algorithm both expect.
  _max30102.setup(
      MAX30102_LED_BRIGHTNESS,
      MAX30102_SAMPLE_AVERAGE,
      2,                                                   // red + IR
      PPG_SAMPLE_RATE_HZ * MAX30102_SAMPLE_AVERAGE,        // pre-average rate
      411,                                                 // pulse width
      MAX30102_ADC_RANGE);
  _max30102Ready = true;
  Serial.printf(
      "[sensor] MAX30102 ready (LED %u, %ux average, %u Hz to the FIFO, "
      "finger threshold IR>=%lu)\n",
      (unsigned)MAX30102_LED_BRIGHTNESS, (unsigned)MAX30102_SAMPLE_AVERAGE,
      (unsigned)(PPG_SAMPLE_RATE_HZ * MAX30102_SAMPLE_AVERAGE),
      (unsigned long)FINGER_IR_THRESHOLD);
}

/// Writes one register, retrying before giving up on the part.
bool SensorNode::writeMpuRegisterRetrying(uint8_t address, uint8_t reg, uint8_t value) {
  for (uint8_t attempt = 0; attempt < 4; ++attempt) {
    if (writeMpuRegister(address, reg, value)) return true;
    delay(5);
  }
  return false;
}

/// Reads the accelerometer once and reports the magnitude in g.
/// Returns NAN if the registers cannot be read.
float SensorNode::readGravityMagnitude(uint8_t address) {
  uint8_t raw[6] = {0};
  if (!readMpuRegisters(address, kMpuRegisterAccelerometerXoutHigh, raw, sizeof(raw))) {
    return NAN;
  }
  const float x = signed16(raw[0], raw[1]) / _accelerometerLsbPerG;
  const float y = signed16(raw[2], raw[3]) / _accelerometerLsbPerG;
  const float z = signed16(raw[4], raw[5]) / _accelerometerLsbPerG;
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
    if (!writeMpuRegisterRetrying(address, kMpuRegisterPowerManagement1, 0x80)) continue;
    delay(100);

    // Retry each write. A single NAK used to abandon the part for good, and on
    // a module whose contact is marginal - one that vanishes from the bus scan
    // between probes, as this one does - losing one byte of five is ordinary.
    // Failing the whole IMU over it reports no motion at all when nine writes
    // in ten would have gone through.
    if (!writeMpuRegisterRetrying(address, kMpuRegisterPowerManagement1, 0x01) ||
        !writeMpuRegisterRetrying(address, kMpuRegisterConfig, 0x03) ||
        !writeMpuRegisterRetrying(address, kMpuRegisterSampleRateDivider, 0x04) ||
        !writeMpuRegisterRetrying(address, kMpuRegisterGyroConfig, 0x08) ||
        !writeMpuRegisterRetrying(address, kMpuRegisterAccelerometerConfig, 0x10)) {
      Serial.printf("[sensor] IMU at 0x%02X did not accept configuration after retries"
                    " - contact is intermittent, check its jumpers and supply\n", address);
      continue;
    }
    // Read the ranges back rather than assuming the writes landed. On this
    // wiring the configuration is accepted intermittently, and a part left at
    // its power-on default while the maths uses the requested scale reports
    // gravity as several g - a number that looks like violent motion from a
    // board lying still.
    uint8_t accelConfig = 0;
    uint8_t gyroConfig = 0;
    if (readMpuRegisters(address, kMpuRegisterAccelerometerConfig, &accelConfig, 1) &&
        readMpuRegisters(address, kMpuRegisterGyroConfig, &gyroConfig, 1)) {
      _accelerometerLsbPerG = accelerometerLsbPerG(accelConfig);
      _gyroscopeLsbPerDps = gyroscopeLsbPerDps(gyroConfig);
      Serial.printf(
          "[sensor] IMU ranges in force: accel %.0f LSB/g, gyro %.1f LSB/dps"
          " (ACCEL_CONFIG 0x%02X, GYRO_CONFIG 0x%02X)\n",
          _accelerometerLsbPerG, _gyroscopeLsbPerDps, accelConfig, gyroConfig);
    } else {
      _accelerometerLsbPerG = kMpuAccelerometerLsbPerG;
      _gyroscopeLsbPerDps = kMpuGyroscopeLsbPerDps;
    }

    // A reset part needs time before its first conversion is meaningful, and
    // how much varies by clone. Poll rather than guess a single delay.
    float magnitude = NAN;
    for (uint8_t attempt = 0; attempt < 10; ++attempt) {
      delay(30);
      magnitude = readGravityMagnitude(address);
      if (!isnan(magnitude) &&
          magnitude >= kGravityPlausibleMinG &&
          magnitude <= kGravityPlausibleMaxG) {
        break;
      }
    }

    _mpu6050Address = address;
    _mpu6050Ready = true;

    // Report an implausible magnitude, but do not refuse the part over it.
    // Rejecting here would repeat the mistake the WHO_AM_I whitelist made:
    // failing closed on a working sensor and reporting nothing at all, which
    // is strictly worse than reporting readings a human can see are wrong.
    if (isnan(magnitude) ||
        magnitude < kGravityPlausibleMinG ||
        magnitude > kGravityPlausibleMaxG) {
      Serial.printf(
          "[sensor] IMU ready at 0x%02X (WHO_AM_I=0x%02X) but reads %.2f g at rest, "
          "expected about 1 g - check it is still and the wiring is sound\n",
          address, identity, magnitude);
    } else {
      Serial.printf("[sensor] IMU ready at 0x%02X (WHO_AM_I=0x%02X, %.2f g at rest)\n",
                    address, identity, magnitude);
    }
    return;
  }

  // Print this at most every 30 s. The probe now runs every 5 s, so an
  // unqualified println here buried the log under one repeated line - and a
  // log nobody can read is how the earlier faults stayed hidden. Throttling it
  // keeps "IMU ready" visible the moment a reseated wire takes effect.
  if (_lastImuMissWarnMs == 0 || millis() - _lastImuMissWarnMs >= 30000) {
    _lastImuMissWarnMs = millis();
    Serial.println(F("[sensor] no usable IMU at 0x68 or 0x69 - check SDA/SCL, 3V3 and GND"));
  }
}

void SensorNode::update() {
  updatePpg();
  updateMotion();
  updateDht22();
  updateRain();
  updateGas();
}

void SensorNode::updatePpg() {
  if (!_max30102Ready) return;

  _max30102.check();

  // Drain everything the FIFO holds, rather than taking one sample per poll.
  //
  // The Maxim algorithm reads a heart rate out of 100 samples by assuming they
  // are evenly spaced at PPG_SAMPLE_RATE_HZ. That assumption is about the
  // sensor's own conversion clock, and the FIFO's samples are evenly spaced
  // whenever they are collected - so draining in bursts keeps the time base
  // exact, while taking one per poll silently throws the rest away and
  // stretches 100 samples across far more than four seconds.
  //
  // The loop is blocked for roughly half of every second: about 460 ms
  // fragmenting telemetry over BLE at 20 ms a fragment, plus up to 400 ms
  // every five seconds re-probing a missing IMU. At one sample per 40 ms poll
  // that collected around twelve samples a second instead of twenty-five, and
  // the algorithm - still dividing by four seconds - returned 93, 166, 115 and
  // 214 bpm from a resting wearer, with SpO2 of 57%. Not noise: a clock error.
  //
  // The FIFO holds 32 samples, 1.28 s at 25 Hz, which covers the worst stall.
  while (_max30102.available()) {
    const uint32_t ir = _max30102.getIR();
    const uint32_t red = _max30102.getRed();
    _max30102.nextSample();
    processPpgSample(ir, red);
  }
}

void SensorNode::processPpgSample(uint32_t ir, uint32_t red) {
  updateSignalQuality(ir);

  if (!_fingerPresent) {
    _heartRateBpm = NAN;
    _spo2Percent = NAN;
    _spo2Valid = false;
    _spo2BufferCount = 0;
    _lastBeatMs = 0;
    _lastRateMs = 0;
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

    // The Maxim algorithm reports a heart rate next to SpO2, and it was being
    // computed and then discarded - every argument passed, filled in, and
    // never read. Heart rate rested entirely on checkForBeat() below, which
    // cannot carry it alone: that routine only accepts a pulse whose AC
    // amplitude lands between 20 and 1000 counts, and through a fingertip at
    // MAX30102_LED_BRIGHTNESS 0x7F the swing runs past that ceiling, so beats
    // are rejected no matter how good the contact is. Raising the brightness
    // is what made contact detection reliable, so the fix is to take the rate
    // from the algorithm that has no such window rather than to dim the LED.
    if (algorithmHeartRateValid && algorithmHeartRate >= 30 &&
        algorithmHeartRate <= 220) {
      const float bpm = static_cast<float>(algorithmHeartRate);
      _heartRateBpm = isnan(_heartRateBpm) ? bpm
                                           : (_heartRateBpm * 0.6f + bpm * 0.4f);
      _lastRateMs = millis();
    }

    if (millis() - _lastPpgLogMs >= 2000) {
      _lastPpgLogMs = millis();
      Serial.printf("[hr] algorithm bpm=%ld valid=%d  spo2=%ld valid=%d\n",
                    (long)algorithmHeartRate, (int)algorithmHeartRateValid,
                    (long)algorithmSpo2, (int)algorithmSpo2Valid);
    }

    // Retain 75 samples so subsequent algorithm results update every second.
    for (uint8_t i = 0; i < 75; ++i) {
      _irBuffer[i] = _irBuffer[i + 25];
      _redBuffer[i] = _redBuffer[i + 25];
    }
    _spo2BufferCount = 75;
  }

  // Kept as the faster path: when the AC amplitude does sit inside its window
  // this updates between algorithm runs instead of once a second.
  if (checkForBeat(ir)) {
    const uint32_t now = millis();
    if (_lastBeatMs != 0) {
      const float bpm = 60000.0f / static_cast<float>(now - _lastBeatMs);
      if (bpm >= 30.0f && bpm <= 220.0f) {
        _heartRateBpm = isnan(_heartRateBpm) ? bpm : (_heartRateBpm * 0.75f + bpm * 0.25f);
        _lastRateMs = now;
      }
    }
    _lastBeatMs = now;
  }

  // Staleness is judged on the last accepted *rate*, from either source. This
  // used to test _lastBeatMs, which only checkForBeat() ever set - so with
  // that routine silent the timer sat at 0 and this branch nulled the heart
  // rate on every pass, discarding a good value the moment it was written.
  if (_lastRateMs == 0 || millis() - _lastRateMs > kFingerTimeoutMs) {
    _heartRateBpm = NAN;
  }
}

void SensorNode::updateSignalQuality(uint32_t irValue) {
  _fingerPresent = irValue >= FINGER_IR_THRESHOLD;

  // Print the raw IR count about once a second. This is the number the
  // threshold has to be set against, and without it a finger that reads just
  // under the line is indistinguishable from no finger at all - which is
  // exactly how heart rate ends up permanently null with the sensor working.
  if (millis() - _lastIrLogMs >= 1000) {
    _lastIrLogMs = millis();
    // 2^18-1 is the top of the ADC range. Railed there the waveform is flat,
    // so no beat can be found however long a finger rests on it - which looks
    // exactly like a working sensor reporting null.
    const bool saturated = irValue >= 262100UL;
    Serial.printf("[ppg] IR=%lu  threshold=%lu  finger=%s%s\n",
                  (unsigned long)irValue,
                  (unsigned long)FINGER_IR_THRESHOLD,
                  _fingerPresent ? "yes" : "no",
                  saturated ? "  SATURATED - lower MAX30102_LED_BRIGHTNESS or"
                              " raise MAX30102_ADC_RANGE" : "");
  }

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
  // The IMU used to be probed once, at boot. A module that was unplugged, or
  // whose 3V3 rail sagged as more sensors were added to it, therefore stayed
  // dead until the board was reflashed - the wiring could be repaired with the
  // firmware still reporting null motion, which points the search at software
  // that is working fine. Retry instead, so fixing the cable is enough.
  if (!_mpu6050Ready) {
    if (millis() - _lastImuProbeMs < kImuProbeIntervalMs) return;
    _lastImuProbeMs = millis();
    beginMpu6050();
    if (!_mpu6050Ready) return;
  }

  if (millis() - _lastMotionReadMs < kMotionIntervalMs) return;
  _lastMotionReadMs = millis();

  uint8_t rawValues[14] = {0};
  if (!readMpuRegisters(
          _mpu6050Address,
          kMpuRegisterAccelerometerXoutHigh,
          rawValues,
          sizeof(rawValues))) {
    // A part that answered at boot and has now stopped has been unplugged or
    // browned out. Drop back to probing so it can come back without a reboot.
    Serial.println(F("[sensor] IMU stopped responding - will re-probe"));
    _mpu6050Ready = false;
    _lastImuProbeMs = millis();
    return;
  }

  _accelerometerXG = signed16(rawValues[0], rawValues[1]) / _accelerometerLsbPerG;
  _accelerometerYG = signed16(rawValues[2], rawValues[3]) / _accelerometerLsbPerG;
  _accelerometerZG = signed16(rawValues[4], rawValues[5]) / _accelerometerLsbPerG;
  _gyroscopeXDps = signed16(rawValues[8], rawValues[9]) / _gyroscopeLsbPerDps;
  _gyroscopeYDps = signed16(rawValues[10], rawValues[11]) / _gyroscopeLsbPerDps;
  _gyroscopeZDps = signed16(rawValues[12], rawValues[13]) / _gyroscopeLsbPerDps;
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
void SensorNode::updateGas() {
#if MQ135_ENABLED
  if (millis() - _lastGasReadMs < kGasIntervalMs) return;
  _lastGasReadMs = millis();

  uint32_t total = 0;
  for (uint8_t i = 0; i < kGasSamples; ++i) {
    total += analogRead(MQ135_ANALOG_PIN);
    delayMicroseconds(200);
  }
  const int raw = static_cast<int>(total / kGasSamples);
  _gasRaw = raw;

  // The heater must reach temperature before the film's resistance means
  // anything. Report null until then rather than publishing the low reading of
  // a cold sensor, which would otherwise look like exceptionally clean air at
  // exactly the moment the device knows least.
  if (millis() < MQ135_WARMUP_MS) {
    _gasIndex = NAN;
    if (millis() - _lastGasLogMs >= 5000) {
      _lastGasLogMs = millis();
      Serial.printf("[mq135] warming up, %lus left (raw %d)\n",
                    (unsigned long)((MQ135_WARMUP_MS - millis()) / 1000), raw);
    }
    return;
  }

  // Rs/R0 from the divider. Rs = RL * (Vmax - Vout) / Vout, and with everything
  // expressed as ADC counts the supply term cancels, leaving counts alone.
  if (raw <= 0 || raw >= 4095) {
    // Rails at either end are not readings. Zero means the pin is grounded or
    // the module is unpowered; full scale usually means AO was wired straight
    // to the pin without a divider, which overdrives a 3.3 V input from a 5 V
    // output. Either way the honest answer is no value.
    _gasIndex = NAN;
    if (millis() - _lastGasLogMs >= 5000) {
      _lastGasLogMs = millis();
      Serial.printf(
          "[mq135] raw %d is at the rail - check AO goes through a divider to a"
          " 3.3 V pin, and that the module has 5 V\n", raw);
    }
    return;
  }

  const float rs = MQ135_LOAD_RESISTANCE_KOHM *
                   (4095.0f - static_cast<float>(raw)) / static_cast<float>(raw);
  const float ratio = rs / (MQ135_LOAD_RESISTANCE_KOHM * MQ135_CLEAN_AIR_RATIO);

  // Ratio falls as contamination rises, so invert it into a rising index. This
  // is a monotonic relative scale, not a concentration: it says "worse than
  // the clean-air reference", never "N micrograms per cubic metre".
  float index = (1.0f - ratio) * 100.0f;
  if (index < 0.0f) index = 0.0f;
  if (index > 100.0f) index = 100.0f;
  _gasIndex = index;

  if (millis() - _lastGasLogMs >= 5000) {
    _lastGasLogMs = millis();
    Serial.printf("[mq135] raw %d  Rs/R0 %.2f  index %.0f\n",
                  raw, ratio, index);
  }
#endif
}

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
  data.gasIndex = _gasIndex;
  data.gasRaw = _gasRaw;
  data.gasValid = !isnan(_gasIndex);
  data.gasReady = MQ135_ENABLED && _gasRaw >= 0;
  data.signalQuality = _signalQuality;
  data.fingerPresent = _fingerPresent;
  data.max30102Ready = _max30102Ready;
  data.mpu6050Ready = _mpu6050Ready;
  data.dht22Ready = _dht22Ready;
  data.oledReady = oledReady;
  return data;
}
