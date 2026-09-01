#include "oled_status.h"

#include "config.h"

bool OledStatus::begin() {
  _ready = _display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDRESS);
  if (!_ready) {
    Serial.println(F("[display] OLED unavailable"));
    return false;
  }
  _display.clearDisplay();
  _display.setTextColor(SSD1306_WHITE);
  _display.setTextSize(1);
  _display.setCursor(0, 0);
  _display.println(F("SwasthyaShield"));
  _display.println(F("Starting BLE..."));
  _display.display();
  Serial.println(F("[display] OLED ready"));
  return true;
}

void OledStatus::render(const TelemetryData& data, bool bleConnected) {
  if (!_ready) return;

  _display.clearDisplay();
  _display.setTextColor(SSD1306_WHITE);
  _display.setTextSize(1);
  _display.setCursor(0, 0);
  _display.print(F("BLE: "));
  _display.println(bleConnected ? F("CONNECTED") : F("ADVERTISING"));

  _display.print(F("HR : "));
  if (data.heartRateValid) _display.print(data.heartRateBpm, 0);
  else _display.print(F("--"));
  _display.println(F(" bpm"));

  _display.print(F("O2 : "));
  if (data.spo2Valid) _display.print(data.spo2Percent, 0);
  else _display.print(F("--"));
  _display.println(F(" %"));

  _display.print(F("Air: "));
  if (data.ambientTemperatureValid) _display.print(data.ambientTemperatureC, 1);
  else _display.print(F("--"));
  _display.println(F(" C"));

  _display.print(F("Q  : "));
  _display.print(data.signalQuality);
  _display.print(F("% "));
  _display.println(data.fingerPresent ? F("FINGER") : F("NO FINGER"));
  _display.display();
}
