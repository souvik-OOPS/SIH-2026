/*
 * TEST 5 — Does the motion sensor work, and can it see a fall?
 *
 * Libraries needed: "Adafruit MPU6050" (installs "Adafruit Unified Sensor" too)
 *
 * Expect: sitting still on the desk, magnitude reads about 1.00 g.
 *         That 1.00 is gravity — it is correct, not an error.
 *
 * Try these:
 *   - lift it up quickly      -> magnitude drops below 1
 *   - tap it on the desk      -> brief spike above 2
 *   - drop it 20cm onto a cushion -> free fall then impact (a real fall)
 *
 * NEVER drop it on a hard surface to test. A cushion or your other hand.
 */

#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

Adafruit_MPU6050 mpu;

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("TEST 5: MPU6050 motion");

  Wire.begin(21, 22);
  if (!mpu.begin(0x68, &Wire)) {
    Serial.println("NOT FOUND. Run TEST 3 first - it must show 0x68.");
    while (1) delay(1000);
  }

  mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  Serial.println("ok. Still on the desk should read about 1.00 g.\n");
}

void loop() {
  sensors_event_t a, g, t;
  mpu.getEvent(&a, &g, &t);

  float x = a.acceleration.x / 9.80665;
  float y = a.acceleration.y / 9.80665;
  float z = a.acceleration.z / 9.80665;
  float mag = sqrt(x * x + y * y + z * z);

  Serial.printf("magnitude %.2f g", mag);
  if (mag < 0.45)      Serial.print("   <- FREE FALL");
  else if (mag > 2.60) Serial.print("   <- IMPACT");
  else if (fabs(mag - 1.0) < 0.18) Serial.print("   (still)");
  Serial.println();

  delay(100);
}
