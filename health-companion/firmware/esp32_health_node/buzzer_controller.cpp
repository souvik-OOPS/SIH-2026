#include "buzzer_controller.h"

#include "config.h"

void BuzzerController::begin() {
  _enabled = ENABLE_BUZZER_DRIVER;
  if (!_enabled) {
    Serial.println(F("[buzzer] disabled: two-pin part needs reviewed driver circuit"));
    return;
  }
  pinMode(BUZZER_DRIVER_PIN, OUTPUT);
  digitalWrite(BUZZER_DRIVER_PIN, LOW);
}

void BuzzerController::triggerBuzzer(uint16_t durationMs) {
  if (!_enabled) return;
  digitalWrite(BUZZER_DRIVER_PIN, HIGH);
  _stopAtMs = millis() + durationMs;
}

void BuzzerController::update() {
  if (_enabled && _stopAtMs != 0 && millis() >= _stopAtMs) {
    digitalWrite(BUZZER_DRIVER_PIN, LOW);
    _stopAtMs = 0;
  }
}
