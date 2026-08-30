/*
 * TEST 6 — Does the temperature/humidity sensor read?
 *
 * Libraries needed: "DHT sensor library" by Adafruit
 *
 * Expect: room temperature (roughly 20-35 C) and humidity (30-80 %).
 *
 * Reads "nan"? That means "not a number" - no valid reply. Causes:
 *   1. DHT22 needs a 10k resistor between DATA and 3V3. If you bought the
 *      3-PIN MODULE (small blue/black PCB), it already has one - fine.
 *      If you bought the BARE 4-PIN SENSOR, you must add the resistor.
 *   2. Wrong pin. This sketch expects DATA on GPIO4.
 *   3. It is slow hardware - the first read or two often fails. Normal.
 *
 * Breathe on the sensor: humidity should jump within a few seconds. That is
 * how you prove it is really reading and not just printing a fixed number.
 */

#include <DHT.h>

#define DHT_PIN  4
#define DHT_TYPE DHT22   // change to DHT11 if you bought the blue DHT11

DHT dht(DHT_PIN, DHT_TYPE);

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("TEST 6: DHT temperature / humidity");
  Serial.printf("DATA on GPIO%d\n\n", DHT_PIN);
  dht.begin();
}

void loop() {
  float h = dht.readHumidity();
  float t = dht.readTemperature();

  if (isnan(h) || isnan(t)) {
    Serial.println("nan - no valid reading (see notes at top)");
  } else {
    Serial.printf("%.1f C   %.0f %% humidity\n", t, h);
  }
  delay(2500);   // DHT22 cannot be read faster than every 2 seconds
}
