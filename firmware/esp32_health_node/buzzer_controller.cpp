#include "buzzer_controller.h"

#include "config.h"

/// Two-pin buzzer driver.
///
/// A two-pin buzzer is a load, not a logic input, so GPIO 25 switches a
/// transistor rather than feeding the buzzer directly (see the README for the
/// circuit). The pin therefore carries only base current, a milliamp or two,
/// well inside the ESP32's limits whatever the buzzer draws.
///
/// Passive vs active matters in software as well as in wiring. A passive
/// buzzer is a bare piezo: a steady HIGH deflects the disc once and it falls
/// silent, so it needs a square wave. An active buzzer has its own oscillator
/// and only needs power. LEDC provides the square wave for the passive case.
void BuzzerController::begin() {
  _enabled = ENABLE_BUZZER_DRIVER;
  if (!_enabled) {
    Serial.println(F("[buzzer] disabled in config"));
    return;
  }

#if BUZZER_IS_PASSIVE
  ledcAttachChannel(BUZZER_DRIVER_PIN, BUZZER_TONE_HZ, 10, BUZZER_LEDC_CHANNEL);
  ledcWrite(BUZZER_DRIVER_PIN, 0);
  Serial.println(F("[buzzer] ready (passive, PWM)"));
#else
  pinMode(BUZZER_DRIVER_PIN, OUTPUT);
  digitalWrite(BUZZER_DRIVER_PIN, LOW);
  Serial.println(F("[buzzer] ready (active, level)"));
#endif
}

void BuzzerController::_on() {
#if BUZZER_IS_PASSIVE
  // ~50% duty is the loudest point for a piezo; higher just clips.
  ledcWrite(BUZZER_DRIVER_PIN, 512);
#else
  digitalWrite(BUZZER_DRIVER_PIN, HIGH);
#endif
  _soundOn = true;
}

void BuzzerController::_off() {
#if BUZZER_IS_PASSIVE
  ledcWrite(BUZZER_DRIVER_PIN, 0);
#else
  digitalWrite(BUZZER_DRIVER_PIN, LOW);
#endif
  _soundOn = false;
}

/// Starts a beep and returns immediately.
///
/// Non-blocking on purpose: this runs on the same loop that services the PPG
/// FIFO and the BLE notifications, and a delay() here would stall telemetry
/// for the length of the beep.
void BuzzerController::triggerBuzzer(uint16_t durationMs) {
  if (!_enabled) return;
  _on();
  _stopAtMs = millis() + durationMs;
}

/// Repeating pattern for a sustained alert, e.g. an unanswered fall check-in.
void BuzzerController::startPattern(uint16_t onMs, uint16_t offMs, uint8_t repeats) {
  if (!_enabled) return;
  _patternOnMs = onMs;
  _patternOffMs = offMs;
  _patternRemaining = repeats;
  _on();
  _stopAtMs = millis() + onMs;
}

void BuzzerController::stop() {
  _patternRemaining = 0;
  _stopAtMs = 0;
  if (_enabled) _off();
}

void BuzzerController::update() {
  if (!_enabled || _stopAtMs == 0) return;
  if (millis() < _stopAtMs) return;

  if (_soundOn) {
    // A pulse just ended. Count it, then either open a gap or finish.
    _off();
    if (_patternRemaining > 0) {
      _patternRemaining--;
      if (_patternRemaining > 0) {
        _stopAtMs = millis() + _patternOffMs;
        return;
      }
    }
    _stopAtMs = 0;
    return;
  }

  // A gap just ended, so start the next pulse.
  _on();
  _stopAtMs = millis() + _patternOnMs;
}
