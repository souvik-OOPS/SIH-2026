/*
 * TEST 4 — Does the pulse sensor read my heartbeat?
 *
 * Library needed: "SparkFun MAX3010x Pulse and Proximity Sensor Library"
 *   Arduino IDE -> Tools -> Manage Libraries -> search "MAX3010x" -> Install
 *
 * HOW TO USE IT PROPERLY (this is where most people give up):
 *   - Rest your FINGERTIP flat on the little glowing sensor window.
 *   - Do NOT press hard. Hard pressure squeezes the blood out of your
 *     fingertip and the reading vanishes. Rest the weight of the finger only.
 *   - Hold completely still for 10-15 seconds. It needs several beats.
 *   - A red LED should be faintly visible on the module when powered.
 *
 * Expect: IR climbs above 50000 when your finger is on, then a BPM appears
 *         and settles somewhere near your real pulse (60-100 at rest).
 *
 * IR stays near 0 with a finger on it? The module is not seeing light —
 * usually a bad solder joint on the header pins.
 */

#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"

MAX30105 ppg;

const byte AVG_LEN = 8;
byte rates[AVG_LEN];
byte rateIndex = 0;
long lastBeat = 0;
float bpm = 0, avgBpm = 0;

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("TEST 4: MAX30102 pulse");

  Wire.begin(21, 22);
  if (!ppg.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("NOT FOUND. Run TEST 3 first - it must show 0x57.");
    while (1) delay(1000);
  }

  ppg.setup(60, 4, 2, 100, 411, 4096);  // brightness, avg, mode, rate, width, range
  ppg.setPulseAmplitudeRed(0x0A);
  ppg.setPulseAmplitudeGreen(0);

  Serial.println("ok. Rest a fingertip on the sensor - light pressure, hold still.\n");
}

void loop() {
  long ir = ppg.getIR();

  if (ir < 50000) {
    Serial.printf("IR %-7ld  no finger detected\n", ir);
    avgBpm = 0;
    delay(400);
    return;
  }

  if (checkForBeat(ir)) {
    long delta = millis() - lastBeat;
    lastBeat = millis();
    bpm = 60000.0 / delta;

    if (bpm > 30 && bpm < 220) {
      rates[rateIndex++] = (byte)bpm;
      rateIndex %= AVG_LEN;
      int sum = 0, n = 0;
      for (byte i = 0; i < AVG_LEN; i++) if (rates[i] > 0) { sum += rates[i]; n++; }
      if (n) avgBpm = (float)sum / n;
      Serial.printf("IR %-7ld  beat!  this=%.0f  average=%.0f bpm\n", ir, bpm, avgBpm);
    }
  }
  delay(20);
}
