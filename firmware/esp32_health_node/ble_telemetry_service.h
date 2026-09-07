#pragma once

#include <BLEDevice.h>

#include "telemetry_types.h"

class BleTelemetryService {
 public:
  static constexpr const char* serviceUuid = "9d5a0001-9d36-4b60-a680-59ab9204d001";
  static constexpr const char* telemetryCharacteristicUuid = "9d5a0002-9d36-4b60-a680-59ab9204d001";

  void begin();
  bool isConnected() const { return _connected; }

 private:
  size_t usableNotifyBytes() const;
  uint16_t _lastFragmentCount = 0;

 public:
  bool publish(const TelemetryData& data, char* jsonOut, size_t jsonOutSize);

  // Used only by the GATT server callbacks in the implementation file.
  void setConnected(bool connected);
  void resumeAdvertising();

 private:
  bool serialize(const TelemetryData& data, char* out, size_t outSize) const;
  void notifyFragments(const char* json);
  void startAdvertising();

  BLEServer* _server = nullptr;
  BLECharacteristic* _telemetryCharacteristic = nullptr;
  bool _connected = false;
  uint16_t _sequence = 0;
};
