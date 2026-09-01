/*
 * Personal Health Companion — ESP32 sensor node
 * SIH 2026, problem statement SIH26181 (Qualcomm)
 *
 * Reads heart rate + SpO2 (MAX30102), ambient temperature + humidity (DHT22)
 * and motion (MPU6050), detects falls on-device, and POSTs a JSON sample to
 * the backend over WiFi.
 *
 * Fall detection runs here rather than on the server on purpose: it needs the
 * accelerometer at ~50 Hz, and shipping 50 samples/second over WiFi would
 * flatten the battery. The board decides; the server only sees the verdict.
 *
 * ---------------------------------------------------------------------------
 * Required libraries (Arduino IDE -> Tools -> Manage Libraries):
 *   - "SparkFun MAX3010x Pulse and Proximity Sensor Library"
 *   - "DHT sensor library"           by Adafruit
 *   - "Adafruit Unified Sensor"      by Adafruit  (dependency of the above)
 *   - "Adafruit MPU6050"             by Adafruit
 *
 * Board: "ESP32 Dev Module" (esp32 core by Espressif)
 *
 * Wiring (I2C devices share SDA/SCL):
 *   MAX30102   VIN->3V3  GND->GND  SDA->GPIO21  SCL->GPIO22
 *   MPU6050    VCC->3V3  GND->GND  SDA->GPIO21  SCL->GPIO22
 *   DHT22      VCC->3V3  GND->GND  DATA->GPIO4  (10k pull-up DATA->3V3)
 * ---------------------------------------------------------------------------
 */

#include <Wire.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <time.h>

#include "MAX30105.h"
#include "spo2_algorithm.h"
#include "heartRate.h"

#include <DHT.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

#include "config.h"

/* ------------------------------- hardware -------------------------------- */

MAX30105 ppg;
DHT dht(DHT_PIN, DHT_TYPE);
Adafruit_MPU6050 mpu;

bool ppgReady = false;
bool mpuReady = false;
bool dhtReady = false;

/* ------------------------------ PPG buffers ------------------------------- */

// The Maxim SpO2 algorithm wants 100 samples at 25 Hz (4 seconds of signal).
#define PPG_BUFFER_LEN 100
uint32_t irBuffer[PPG_BUFFER_LEN];
uint32_t redBuffer[PPG_BUFFER_LEN];
int ppgIndex = 0;
bool ppgBufferFull = false;
unsigned long lastPpgSampleMs = 0;

// Beat-to-beat heart rate, averaged over the last few beats.
#define BEAT_AVG_LEN 6
byte beatRates[BEAT_AVG_LEN];
byte beatIndex = 0;
long lastBeatMs = 0;
float beatAvg = 0;

int32_t spo2Value = 0;
int8_t spo2Valid = 0;
int32_t hrFromAlgo = 0;
int8_t hrValid = 0;

/* --------------------------- fall-detection state -------------------------- */

/*
 * A fall has a three-part signature, and requiring all three is what keeps
 * "phone put down on a table" from paging a caregiver:
 *   1. free fall      — magnitude drops well below 1 g
 *   2. impact         — a sharp spike shortly after
 *   3. stillness      — the body does not move for a couple of seconds
 */
#define FREEFALL_G       0.45f
#define IMPACT_G         2.60f
#define FREEFALL_WINDOW  1200UL   // ms: impact must follow free fall within this
#define STILLNESS_MS     2000UL   // ms of no movement to confirm
#define STILLNESS_BAND   0.18f    // |g - 1.0| below this counts as still

enum FallStage { FALL_IDLE, FALL_FREEFALL, FALL_IMPACT, FALL_CONFIRMED };
FallStage fallStage = FALL_IDLE;
unsigned long fallStageAt = 0;
unsigned long stillSinceMs = 0;
bool fallPending = false;      // latched until the next POST reports it
float lastImpactG = 0;

float accelMagnitudeG = 1.0f;
unsigned long lastMotionReadMs = 0;
const unsigned long MOTION_INTERVAL_MS = 20;  // ~50 Hz

// Rolling movement estimate, used to classify rest/light/active.
float motionEnergy = 0;
// A gravity-magnitude-only detector reports "rest" when the wearer rotates
// their wrist. Keep the prior acceleration vector and include gyro movement.
float previousAccelXG = 0;
float previousAccelYG = 0;
float previousAccelZG = 0;
bool  havePreviousAccel = false;
float accelDeltaG = 0;
float gyroMagnitudeDps = 0;

/* --------------------------------- timing --------------------------------- */

unsigned long lastSendMs = 0;
unsigned long lastWifiCheckMs = 0;

/* ================================= setup ================================== */

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println(F("Personal Health Companion — sensor node"));

  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(400000);

  initSensors();
  connectWifi();
  syncClock();

  Serial.println(F("ready.\n"));
}

void initSensors() {
  // --- MAX30102 ---
  if (ppg.begin(Wire, I2C_SPEED_FAST)) {
    // Settings from SparkFun's SpO2 example: these give a usable red/IR ratio.
    byte ledBrightness = 60;   // 0 = off, 255 = ~50 mA
    byte sampleAverage = 4;
    byte ledMode       = 2;    // red + IR
    byte sampleRate    = 100;
    int  pulseWidth    = 411;
    int  adcRange      = 4096;
    ppg.setup(ledBrightness, sampleAverage, ledMode, sampleRate, pulseWidth, adcRange);
    ppgReady = true;
    Serial.println(F("  MAX30102 ok"));
  } else {
    Serial.println(F("  MAX30102 NOT FOUND — check I2C wiring"));
  }

  // --- MPU6050 ---
  if (mpu.begin(0x68, &Wire)) {
    mpu.setAccelerometerRange(MPU6050_RANGE_8_G);   // falls exceed 4 g easily
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    mpuReady = true;
    Serial.println(F("  MPU6050 ok"));
  } else {
    Serial.println(F("  MPU6050 NOT FOUND"));
  }

  // --- DHT22 ---
  dht.begin();
  dhtReady = true;
  Serial.println(F("  DHT started"));
}

void connectWifi() {
  Serial.print(F("  WiFi connecting to "));
  Serial.print(WIFI_SSID);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    delay(400);
    Serial.print('.');
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print(F(" connected, ip="));
    Serial.println(WiFi.localIP());
  } else {
    // Not fatal. The node keeps sensing and retries; this is the "works during
    // a network outage" requirement in its most basic form.
    Serial.println(F(" FAILED (will retry in the background)"));
  }
}

void syncClock() {
  if (WiFi.status() != WL_CONNECTED) return;
  // IST. Without this the device stamps samples from 1970 and the backend
  // has to fall back to server time.
  configTime(5 * 3600 + 1800, 0, "pool.ntp.org", "time.nist.gov");

  struct tm t;
  if (getLocalTime(&t, 5000)) {
    Serial.println(F("  clock synced"));
  } else {
    Serial.println(F("  clock sync failed — server will timestamp instead"));
  }
}

/* ================================== loop ================================== */

void loop() {
  readMotion();
  readPpg();

  if (millis() - lastSendMs >= SEND_INTERVAL_MS) {
    lastSendMs = millis();
    sendSample();
  }

  // A confirmed fall must not wait up to SEND_INTERVAL_MS to be reported.
  if (fallPending && fallStage == FALL_CONFIRMED) {
    sendSample();
    lastSendMs = millis();
  }

  if (millis() - lastWifiCheckMs > 15000) {
    lastWifiCheckMs = millis();
    if (WiFi.status() != WL_CONNECTED) {
      Serial.println(F("  WiFi dropped, reconnecting"));
      WiFi.reconnect();
    }
  }
}

/* ------------------------------ motion + falls ---------------------------- */

void readMotion() {
  if (!mpuReady) return;
  if (millis() - lastMotionReadMs < MOTION_INTERVAL_MS) return;
  lastMotionReadMs = millis();

  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  // Adafruit reports m/s^2; convert to g.
  float ax = a.acceleration.x / 9.80665f;
  float ay = a.acceleration.y / 9.80665f;
  float az = a.acceleration.z / 9.80665f;
  accelMagnitudeG = sqrtf(ax * ax + ay * ay + az * az);

  accelDeltaG = 0;
  if (havePreviousAccel) {
    const float dx = ax - previousAccelXG;
    const float dy = ay - previousAccelYG;
    const float dz = az - previousAccelZG;
    accelDeltaG = sqrtf(dx * dx + dy * dy + dz * dz);
  }
  previousAccelXG = ax;
  previousAccelYG = ay;
  previousAccelZG = az;
  havePreviousAccel = true;

  // Adafruit reports angular velocity in rad/s; convert it to degrees/s.
  gyroMagnitudeDps = sqrtf(g.gyro.x * g.gyro.x + g.gyro.y * g.gyro.y + g.gyro.z * g.gyro.z) * 57.29578f;
  const float gravityDeviation = fabsf(accelMagnitudeG - 1.0f);
  const float instantMotion = fmaxf(gravityDeviation, fmaxf(accelDeltaG * 1.5f, gyroMagnitudeDps / 100.0f));
  motionEnergy = motionEnergy * 0.88f + instantMotion * 0.12f;

  updateFallState();
}

void updateFallState() {
  unsigned long nowMs = millis();
  float dev = fabsf(accelMagnitudeG - 1.0f);

  switch (fallStage) {
    case FALL_IDLE:
      if (accelMagnitudeG < FREEFALL_G) {
        fallStage = FALL_FREEFALL;
        fallStageAt = nowMs;
      }
      break;

    case FALL_FREEFALL:
      if (accelMagnitudeG > IMPACT_G) {
        fallStage = FALL_IMPACT;
        fallStageAt = nowMs;
        stillSinceMs = 0;
        lastImpactG = accelMagnitudeG;
      } else if (nowMs - fallStageAt > FREEFALL_WINDOW) {
        fallStage = FALL_IDLE;   // free fall with no impact — not a fall
      }
      break;

    case FALL_IMPACT:
      if (dev < STILLNESS_BAND) {
        if (stillSinceMs == 0) stillSinceMs = nowMs;
        if (nowMs - stillSinceMs >= STILLNESS_MS) {
          fallStage = FALL_CONFIRMED;
          fallPending = true;
          Serial.print(F("  ** FALL CONFIRMED  impact="));
          Serial.print(lastImpactG, 2);
          Serial.println(F(" g"));
        }
      } else {
        stillSinceMs = 0;
        // Moving again within 5s of impact — they got up, so not a fall.
        if (nowMs - fallStageAt > 5000) fallStage = FALL_IDLE;
      }
      break;

    case FALL_CONFIRMED:
      // Held until sendSample() reports it, then released once they move again.
      if (!fallPending && dev > STILLNESS_BAND) fallStage = FALL_IDLE;
      break;
  }
}

const char* motionLabel() {
  if (!mpuReady) return "unknown";
  if (motionEnergy < 0.045f) return "rest";
  if (motionEnergy < 0.18f) return "light";
  return "active";
}

/* --------------------------------- PPG ------------------------------------ */

void readPpg() {
  if (!ppgReady) return;

  unsigned long interval = 1000UL / PPG_SAMPLE_HZ;
  if (millis() - lastPpgSampleMs < interval) return;
  lastPpgSampleMs = millis();

  if (!ppg.available()) ppg.check();
  if (!ppg.available()) return;

  uint32_t ir = ppg.getIR();
  uint32_t red = ppg.getRed();
  ppg.nextSample();

  irBuffer[ppgIndex] = ir;
  redBuffer[ppgIndex] = red;
  ppgIndex = (ppgIndex + 1) % PPG_BUFFER_LEN;
  if (ppgIndex == 0) ppgBufferFull = true;

  // Beat detection gives a faster, more responsive HR than the Maxim algorithm.
  if (checkForBeat(ir)) {
    long delta = millis() - lastBeatMs;
    lastBeatMs = millis();
    float bpm = 60000.0f / (float)delta;

    if (bpm > 30 && bpm < 220) {
      beatRates[beatIndex++] = (byte)bpm;
      beatIndex %= BEAT_AVG_LEN;

      int sum = 0, n = 0;
      for (byte i = 0; i < BEAT_AVG_LEN; i++) {
        if (beatRates[i] > 0) { sum += beatRates[i]; n++; }
      }
      if (n) beatAvg = (float)sum / n;
    }
  }
}

/** Below this IR level nothing is touching the sensor. */
bool fingerPresent() {
  if (!ppgReady) return false;
  return ppg.getIR() > 50000;
}

void computeSpo2() {
  if (!ppgReady || !ppgBufferFull) return;
  maxim_heart_rate_and_oxygen_saturation(
    irBuffer, PPG_BUFFER_LEN, redBuffer,
    &spo2Value, &spo2Valid, &hrFromAlgo, &hrValid
  );
}

/* -------------------------------- transmit -------------------------------- */

/** ISO-8601 UTC timestamp, or an empty string if the clock never synced. */
void isoTimestamp(char* out, size_t len) {
  time_t nowSec = time(nullptr);
  if (nowSec < 1700000000) { out[0] = '\0'; return; }  // clock clearly unset
  struct tm tmUtc;
  gmtime_r(&nowSec, &tmUtc);
  strftime(out, len, "%Y-%m-%dT%H:%M:%SZ", &tmUtc);
}

void sendSample() {
  computeSpo2();

  bool finger = fingerPresent();

  float humidity = dhtReady ? dht.readHumidity() : NAN;
  float ambientC = dhtReady ? dht.readTemperature() : NAN;

  int heartRate = -1;
  if (finger && beatAvg > 30 && beatAvg < 220) heartRate = (int)beatAvg;
  else if (finger && hrValid && hrFromAlgo > 30 && hrFromAlgo < 220) heartRate = (int)hrFromAlgo;

  int spo2 = (finger && spo2Valid && spo2Value > 50 && spo2Value <= 100) ? (int)spo2Value : -1;

  bool reportFall = fallPending;

  char ts[32];
  isoTimestamp(ts, sizeof(ts));

  // Build JSON by hand — one small buffer, no ArduinoJson dependency.
  char body[420];
  int n = snprintf(body, sizeof(body), "{\"deviceId\":\"%s\"", DEVICE_ID);

  if (heartRate > 0) n += snprintf(body + n, sizeof(body) - n, ",\"heartRate\":%d", heartRate);
  if (spo2 > 0)      n += snprintf(body + n, sizeof(body) - n, ",\"spo2\":%d", spo2);
  if (!isnan(ambientC)) n += snprintf(body + n, sizeof(body) - n, ",\"ambientTemp\":%.1f", ambientC);
  if (!isnan(humidity)) n += snprintf(body + n, sizeof(body) - n, ",\"humidity\":%.0f", humidity);

  n += snprintf(body + n, sizeof(body) - n, ",\"accelMagnitude\":%.2f", accelMagnitudeG);
  n += snprintf(body + n, sizeof(body) - n, ",\"motion\":\"%s\"", motionLabel());
  n += snprintf(body + n, sizeof(body) - n, ",\"fallDetected\":%s", reportFall ? "true" : "false");
  // signalOk tells the dashboard whether to trust the PPG-derived numbers.
  n += snprintf(body + n, sizeof(body) - n, ",\"signalOk\":%s", finger ? "true" : "false");
  if (ts[0]) n += snprintf(body + n, sizeof(body) - n, ",\"timestamp\":\"%s\"", ts);

  snprintf(body + n, sizeof(body) - n, "}");

  Serial.print(F("  -> "));
  Serial.println(body);

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println(F("     (offline — sample dropped)"));
    return;
  }

  HTTPClient http;
  http.begin(SERVER_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("x-api-key", DEVICE_API_KEY);
  http.setTimeout(5000);

  int code = http.POST((uint8_t*)body, strlen(body));

  if (code > 0) {
    Serial.print(F("     HTTP "));
    Serial.println(code);
    // Only clear the latch once the server has actually accepted the fall,
    // so a dropped packet cannot silently lose a fall event.
    if (code >= 200 && code < 300 && reportFall) {
      fallPending = false;
    }
  } else {
    Serial.print(F("     POST failed: "));
    Serial.println(http.errorToString(code));
  }

  http.end();
}
