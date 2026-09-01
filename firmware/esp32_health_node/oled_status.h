#pragma once

#include <Adafruit_SSD1306.h>
#include <Wire.h>

#include "telemetry_types.h"

class OledStatus {
 public:
  bool begin();
  void render(const TelemetryData& data, bool bleConnected);
  bool isReady() const { return _ready; }

 private:
  Adafruit_SSD1306 _display{128, 64, &Wire, -1};
  bool _ready = false;
};
