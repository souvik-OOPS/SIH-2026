#pragma once

#include <Arduino.h>

class BuzzerController {
 public:
  void begin();
  void update();
  void triggerBuzzer(uint16_t durationMs = 80);

 private:
  bool _enabled = false;
  uint32_t _stopAtMs = 0;
};
