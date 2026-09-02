#pragma once

#include <Arduino.h>

/// Non-blocking driver for the two-pin buzzer on GPIO 25.
///
/// Every call returns immediately and `update()` does the timing, because this
/// shares a loop with the PPG FIFO and the BLE notifications — a `delay()` for
/// the length of a beep would stall telemetry.
class BuzzerController {
 public:
  void begin();
  void update();

  /// Single beep.
  void triggerBuzzer(uint16_t durationMs = 80);

  /// Repeating pulse train, for a sustained alert such as an unanswered
  /// fall check-in.
  void startPattern(uint16_t onMs, uint16_t offMs, uint8_t repeats);

  /// Silences immediately and abandons any pattern in progress.
  void stop();

  bool isEnabled() const { return _enabled; }

 private:
  void _on();
  void _off();

  bool _enabled = false;

  /// True while the buzzer is actually sounding, as opposed to sitting in the
  /// gap between two pulses. `update()` needs the difference to know whether
  /// the next deadline ends a pulse or ends a silence.
  bool _soundOn = false;

  uint32_t _stopAtMs = 0;
  uint16_t _patternOnMs = 0;
  uint16_t _patternOffMs = 0;
  uint8_t _patternRemaining = 0;
};
