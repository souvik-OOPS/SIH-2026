/*
 * SwasthyaShield Edge — Day 2 BLE sensor node.
 *
 * Board: ESP32 Dev Module. This sketch is intentionally independent of the
 * legacy Wi-Fi firmware and requires no network credentials or backend.
 */

#include "ble_telemetry_service.h"
#include "buzzer_controller.h"
#include "oled_status.h"
#include "sensor_node.h"

#include "config.h"

namespace {
SensorNode sensors;
OledStatus oled;
BuzzerController buzzer;
BleTelemetryService ble;
uint32_t lastTelemetryMs = 0;
}  // namespace

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println(F("SwasthyaShield Edge — Day 2 BLE node"));

  sensors.begin();
  oled.begin();
  buzzer.begin();
  ble.begin();
}

void loop() {
  sensors.update();
  buzzer.update();

  if (millis() - lastTelemetryMs < TELEMETRY_INTERVAL_MS) return;
  lastTelemetryMs = millis();

  const TelemetryData data = sensors.snapshot(oled.isReady());
  oled.render(data, ble.isConnected());

  char packet[240] = {0};
  const bool sent = ble.publish(data, packet, sizeof(packet));
  Serial.print(F("[telemetry] "));
  Serial.print(packet);
  Serial.println(sent ? F("  [BLE sent]") : F("  [BLE waiting for phone]"));
}
