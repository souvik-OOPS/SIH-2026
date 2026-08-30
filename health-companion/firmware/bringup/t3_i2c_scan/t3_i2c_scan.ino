/*
 * TEST 3 — Is my wiring correct?  <-- THE MOST IMPORTANT TEST
 *
 * Proves: the MAX30102 and MPU6050 are wired correctly and talking.
 *         Run this after wiring, BEFORE trying any sensor library.
 *
 * Every I2C device has an address. You should see:
 *   0x57  = MAX30102  (heart rate / SpO2)
 *   0x68  = MPU6050   (motion / falls)
 *
 * Expect: "found 2 device(s)" listing both.
 *
 * Found NOTHING? 99% of the time it is one of these, in order:
 *   1. SDA and SCL swapped
 *   2. no power — check 3V3 and GND actually reach the module
 *   3. header pins not soldered (pushed in but not soldered = no connection)
 *
 * Found only one? That module is the problem — the other is fine.
 */

#include <Wire.h>

#define I2C_SDA 21
#define I2C_SCL 22

void setup() {
  Serial.begin(115200);
  delay(500);
  Wire.begin(I2C_SDA, I2C_SCL);
  Serial.println();
  Serial.println("TEST 3: I2C scan");
  Serial.printf("SDA=GPIO%d  SCL=GPIO%d\n\n", I2C_SDA, I2C_SCL);
}

void loop() {
  int found = 0;

  for (byte addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      Serial.printf("  found device at 0x%02X", addr);
      if (addr == 0x57) Serial.print("   <- MAX30102 (heart rate / SpO2)");
      if (addr == 0x68) Serial.print("   <- MPU6050 (motion)");
      if (addr == 0x69) Serial.print("   <- MPU6050 (AD0 pulled high)");
      Serial.println();
      found++;
    }
  }

  if (found == 0) Serial.println("  nothing found - check wiring (see notes at top)");
  Serial.printf("found %d device(s)\n\n", found);
  delay(4000);
}
