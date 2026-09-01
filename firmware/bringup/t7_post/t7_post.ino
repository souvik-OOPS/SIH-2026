/*
 * TEST 7 — Can the board reach my backend and does a reading appear?
 *
 * This is the last test before the real firmware. It sends ONE fake reading
 * every 5 seconds. No sensors involved - it is purely a network test.
 *
 * BEFORE UPLOADING, edit the four lines below.
 *
 * FINDING YOUR LAPTOP'S IP (this is the step people get wrong):
 *   Windows PowerShell:  ipconfig
 *     -> look for "IPv4 Address" under your WiFi adapter, e.g. 192.168.1.42
 *   It is NEVER "localhost" and NEVER 127.0.0.1 - those mean "the ESP32
 *   itself", so the board would be talking to nobody.
 *
 * The laptop and the board must be on the SAME WiFi network.
 *
 * Expect: "HTTP 200" here, and a heart rate appearing on the dashboard.
 *
 * HTTP 401  -> DEVICE_API_KEY does not match DEVICE_API_KEY in backend/.env
 * -1 / -11  -> cannot reach the laptop. Backend not running, wrong IP, or
 *              Windows Firewall is blocking port 4000 (see BRINGUP.md).
 */

#include <WiFi.h>
#include <HTTPClient.h>

const char* SSID       = "PUT_YOUR_WIFI_NAME_HERE";
const char* PASSWORD   = "PUT_YOUR_WIFI_PASSWORD_HERE";
const char* SERVER_URL = "http://192.168.1.100:4000/api/ingest";  // <- your laptop IP
const char* API_KEY    = "sih26181-dev-key";

int fakeHr = 72;

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("TEST 7: POST to backend");

  WiFi.mode(WIFI_STA);
  WiFi.begin(SSID, PASSWORD);
  Serial.print("wifi");
  while (WiFi.status() != WL_CONNECTED) { delay(400); Serial.print('.'); }
  Serial.print(" ok, ip=");
  Serial.println(WiFi.localIP());
  Serial.printf("posting to %s\n\n", SERVER_URL);
}

void loop() {
  // Walk the fake heart rate up and down so you can see it move on screen.
  fakeHr += random(-3, 4);
  if (fakeHr < 60) fakeHr = 60;
  if (fakeHr > 100) fakeHr = 100;

  char body[220];
  snprintf(body, sizeof(body),
    "{\"deviceId\":\"band-001\",\"heartRate\":%d,\"spo2\":97,"
    "\"ambientTemp\":29.5,\"humidity\":55,\"accelMagnitude\":1.02,"
    "\"motion\":\"rest\",\"fallDetected\":false,\"signalOk\":true}", fakeHr);

  HTTPClient http;
  http.begin(SERVER_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("x-api-key", API_KEY);
  http.setTimeout(5000);

  int code = http.POST((uint8_t*)body, strlen(body));

  if (code > 0) {
    Serial.printf("HR %d  ->  HTTP %d", fakeHr, code);
    if (code == 200) Serial.print("   check the dashboard!");
    if (code == 401) Serial.print("   API key mismatch");
    Serial.println();
  } else {
    Serial.printf("HR %d  ->  FAILED (%s)\n", fakeHr, http.errorToString(code).c_str());
    Serial.println("   backend running? correct IP? firewall?");
  }

  http.end();
  delay(5000);
}
