/*
 * TEST 2 — Can the board join your WiFi?
 *
 * Proves: SSID/password correct, board reaches your network, and you learn
 *         the board's IP. Still nothing wired.
 *
 * EDIT the two lines below before uploading.
 *
 * Expect: "connected, ip=192.168.x.x"
 *
 * IMPORTANT: ESP32 only joins 2.4 GHz networks. If your phone hotspot or
 * router is 5 GHz only, it will never connect. Most home routers broadcast
 * both — pick the 2.4 GHz one.
 */

#include <WiFi.h>

const char* SSID     = "PUT_YOUR_WIFI_NAME_HERE";
const char* PASSWORD = "PUT_YOUR_WIFI_PASSWORD_HERE";

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("TEST 2: wifi");
  Serial.printf("connecting to \"%s\"", SSID);

  WiFi.mode(WIFI_STA);
  WiFi.begin(SSID, PASSWORD);

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    delay(400);
    Serial.print('.');
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("connected, ip=");
    Serial.println(WiFi.localIP());
    Serial.print("signal strength (closer to 0 is better): ");
    Serial.println(WiFi.RSSI());
    Serial.println("\nWrite this IP down — you do NOT need it, but if the board");
    Serial.println("and your laptop are on different subnets, that's the clue.");
  } else {
    Serial.println("FAILED. Check: 2.4 GHz network? password exactly right?");
    Serial.println("Network names are case-sensitive.");
  }
}

void loop() {}
