/*
 * TEST 1 — Is the board alive and can I flash it?
 *
 * Proves: USB cable carries data, driver installed, board type correct,
 *         upload works. Nothing is wired yet. Do this FIRST.
 *
 * Expect: the small blue LED on the board blinks once a second, and the
 *         Serial Monitor (115200 baud) counts upward.
 *
 * If upload fails with "Failed to connect": hold the BOOT button while it
 * says "Connecting........", release when it starts writing.
 */

#define LED_PIN 2   // built-in LED on most ESP32 DevKit boards

int count = 0;

void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(LED_PIN, OUTPUT);
  Serial.println();
  Serial.println("TEST 1: blink");
  Serial.println("If you can read this, the board and cable are fine.");
}

void loop() {
  digitalWrite(LED_PIN, HIGH);
  delay(500);
  digitalWrite(LED_PIN, LOW);
  delay(500);
  Serial.printf("alive %d\n", ++count);
}
