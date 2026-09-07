#include "ble_telemetry_service.h"

#include <BLE2902.h>

#include "config.h"

namespace {
constexpr size_t kJsonBufferSize = 240;
constexpr size_t kSafeNotifyBytes = 20;  // default ATT MTU (23) minus 3-byte header
constexpr size_t kMaxNotifyBytes = 220;  // ceiling for the fragment buffer
constexpr size_t kFragmentHeaderBytes = 12;  // "@999,99/99:" plus a margin
// A default-MTU frame takes about 20 notifications. Android can silently drop
// a burst that is queued faster than its BLE connection interval, leaving the
// phone unable to reassemble any frame. This stays well inside the 1 Hz
// telemetry budget while making the ordered transport reliable on phones.
constexpr uint16_t kFragmentIntervalMs = 20;

class ServerCallbacks final : public BLEServerCallbacks {
 public:
  explicit ServerCallbacks(BleTelemetryService* service) : _service(service) {}

  void onConnect(BLEServer*) override { _service->setConnected(true); }
  void onDisconnect(BLEServer*) override {
    _service->setConnected(false);
    _service->resumeAdvertising();
  }

 private:
  BleTelemetryService* _service;
};
}  // namespace

// Keep the callback's hardware-facing hooks private to this translation unit.
// They are declared here rather than exposing BLE implementation to the sketch.
void BleTelemetryService::setConnected(bool connected) {
  _connected = connected;
  Serial.println(connected ? F("[ble] central connected")
                           : F("[ble] central disconnected"));
}
void BleTelemetryService::resumeAdvertising() { BLEDevice::getAdvertising()->start(); }

void BleTelemetryService::begin() {
  BLEDevice::init(BLE_DEVICE_NAME);
  BLEDevice::setMTU(185);

  _server = BLEDevice::createServer();
  _server->setCallbacks(new ServerCallbacks(this));
  BLEService* service = _server->createService(serviceUuid);
  _telemetryCharacteristic = service->createCharacteristic(
      telemetryCharacteristicUuid,
      BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ);
  _telemetryCharacteristic->addDescriptor(new BLE2902());
  _telemetryCharacteristic->setValue("{}");
  service->start();
  startAdvertising();

  Serial.print(F("[ble] advertising as "));
  Serial.println(BLE_DEVICE_NAME);
}

// Registers the service UUID exactly once. addServiceUUID() appends to a
// std::vector, so calling it per reconnect would grow the advertised list and
// flip the AD type from "complete" to "incomplete" after the first disconnect.
void BleTelemetryService::startAdvertising() {
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(serviceUuid);
  advertising->setScanResponse(true);
  advertising->start();
}

bool BleTelemetryService::publish(const TelemetryData& data, char* jsonOut, size_t jsonOutSize) {
  if (!serialize(data, jsonOut, jsonOutSize)) return false;
  if (_connected) notifyFragments(jsonOut);
  return _connected;
}

bool BleTelemetryService::serialize(const TelemetryData& data, char* out, size_t outSize) const {
  if (outSize < kJsonBufferSize) return false;

  char heartRate[12];
  char spo2[12];
  char temperature[12];
  char humidity[12];
  char ax[12];
  char ay[12];
  char az[12];
  char gx[12];
  char gy[12];
  char gz[12];
  char rain[12];
  char gas[12];
  const char* heartRateValue = data.heartRateValid
                                   ? dtostrf(data.heartRateBpm, 0, 1, heartRate)
                                   : "null";
  const char* spo2Value = data.spo2Valid ? dtostrf(data.spo2Percent, 0, 1, spo2) : "null";
  const char* temperatureValue = data.ambientTemperatureValid
                                     ? dtostrf(data.ambientTemperatureC, 0, 1, temperature)
                                     : "null";
  const char* humidityValue = data.humidityValid
                                  ? dtostrf(data.humidityPercent, 0, 1, humidity)
                                  : "null";
  const char* axValue = data.accelerometerValid
                            ? dtostrf(data.accelerometerXG, 0, 2, ax)
                            : "null";
  const char* ayValue = data.accelerometerValid
                            ? dtostrf(data.accelerometerYG, 0, 2, ay)
                            : "null";
  const char* azValue = data.accelerometerValid
                            ? dtostrf(data.accelerometerZG, 0, 2, az)
                            : "null";
  const char* gxValue = data.gyroscopeValid
                            ? dtostrf(data.gyroscopeXDps, 0, 1, gx)
                            : "null";
  const char* gyValue = data.gyroscopeValid
                            ? dtostrf(data.gyroscopeYDps, 0, 1, gy)
                            : "null";
  const char* gzValue = data.gyroscopeValid
                            ? dtostrf(data.gyroscopeZDps, 0, 1, gz)
                            : "null";
  const char* rainValue =
      data.rainValid ? dtostrf(data.rainWetnessPercent, 0, 0, rain) : "null";
  // "gas", not "aqi". The MQ-135 gives a relative gas-mixture index and no
  // particulate measurement, so naming the field aqi would let the app render
  // an uncalibrated resistance as a public-health number.
  const char* gasValue =
      data.gasValid ? dtostrf(data.gasIndex, 0, 0, gas) : "null";

  const int written = snprintf(
      out,
      outSize,
      "{\"v\":1,\"u\":%lu,\"hr\":%s,\"o2\":%s,\"t\":%s,\"h\":%s,\"ax\":%s,\"ay\":%s,\"az\":%s,\"gx\":%s,\"gy\":%s,\"gz\":%s,\"rain\":%s,\"rr\":%d,\"gas\":%s,\"gr\":%d,\"q\":%u,\"f\":%u}",
      static_cast<unsigned long>(data.uptimeMillis),
      heartRateValue,
      spo2Value,
      temperatureValue,
      humidityValue,
      axValue,
      ayValue,
      azValue,
      gxValue,
      gyValue,
      gzValue,
      rainValue,
      data.rainRaw,
      gasValue,
      data.gasRaw,
      data.signalQuality,
      data.fingerPresent ? 1 : 0);
  return written > 0 && static_cast<size_t>(written) < outSize;
}

/// Bytes of JSON that fit in one notification on the link as negotiated.
///
/// setMTU(185) only states what this device is willing to accept; the value
/// actually in force is whatever the phone agreed to, and it is not known
/// until a phone connects. The old code asked for 185 and then fragmented at
/// 20 regardless, so every packet went out as two dozen notifications of seven
/// JSON bytes each - on a link that had already agreed to carry the whole
/// thing in one.
///
/// That cost far more than airtime. The app discards an entire packet if any
/// single fragment is lost or arrives out of order, so one dropped
/// notification in twenty-four threw away the whole reading: the OLED showed a
/// heart rate the phone never received. And the 20 ms pacing between fragments
/// blocked the main loop for about 460 ms of every second, which starved the
/// pulse sensor of samples.
size_t BleTelemetryService::usableNotifyBytes() const {
  if (_server == nullptr) return kSafeNotifyBytes;
  const uint16_t mtu = _server->getPeerMTU(_server->getConnId());
  // Anything at or below the 23-byte default means no useful negotiation
  // happened; fall back rather than trust a surprising number.
  if (mtu <= 23) return kSafeNotifyBytes;
  size_t usable = static_cast<size_t>(mtu) - 3;  // ATT notification header
  if (usable > kMaxNotifyBytes) usable = kMaxNotifyBytes;
  if (usable < kSafeNotifyBytes) usable = kSafeNotifyBytes;
  return usable;
}

void BleTelemetryService::notifyFragments(const char* json) {
  const size_t length = strlen(json);
  const uint16_t sequence = _sequence++ % 1000;

  const size_t notifyBytes = usableNotifyBytes();
  const size_t dataBytes = notifyBytes > kFragmentHeaderBytes
                               ? notifyBytes - kFragmentHeaderBytes
                               : 7;
  const uint16_t total = (length + dataBytes - 1) / dataBytes;

  // The framing is unchanged, so a single-fragment packet is just "@N,1/1:"
  // and the phone reassembles it through the same path as before.
  if (total != _lastFragmentCount) {
    _lastFragmentCount = total;
    Serial.printf("[ble] MTU gives %u usable bytes: %u fragment%s per packet\n",
                  (unsigned)notifyBytes, (unsigned)total, total == 1 ? "" : "s");
  }

  for (uint16_t part = 1; part <= total; ++part) {
    const size_t offset = (part - 1) * dataBytes;
    const size_t remaining = length - offset;
    const size_t take = min(dataBytes, remaining);
    char fragment[kMaxNotifyBytes + 1] = {0};
    const int headerLength = snprintf(fragment, sizeof(fragment), "@%u,%u/%u:", sequence, part, total);
    if (headerLength <= 0 || static_cast<size_t>(headerLength) + take > notifyBytes) {
      Serial.println(F("[ble] fragment framing error"));
      return;
    }
    memcpy(fragment + headerLength, json + offset, take);
    _telemetryCharacteristic->setValue(reinterpret_cast<uint8_t*>(fragment), headerLength + take);
    _telemetryCharacteristic->notify();
    if (part < total) delay(kFragmentIntervalMs);
  }
}
