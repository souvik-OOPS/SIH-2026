# ESP32 Day 2 BLE sensor node

This is the BLE-only Day 2 firmware. It does not use Wi-Fi, a backend, or cloud services.

## Install in Arduino IDE

Select **ESP32 Dev Module** and install:

- SparkFun MAX3010x Pulse and Proximity Sensor Library
- DHT sensor library by Adafruit
- Adafruit Unified Sensor
- Adafruit MPU6050
- Adafruit SSD1306
- Adafruit GFX Library

The ESP32 Arduino board package supplies the `BLEDevice` library.

Copy `config.example.h` to `config.h`. Keep `ENABLE_BUZZER_DRIVER` set to `false`: the connected buzzer has two pins and must not be driven from an ESP32 GPIO without a reviewed driver circuit.

## Safety and current Day 2 limits

- DHT22 values are ambient temperature and relative humidity only; this firmware does not claim body temperature.
- Heart rate is shown only while the MAX30102 contact heuristic sees a finger and plausible beats.
- The bundled SparkFun/Maxim reference algorithm reports `o2` only after four seconds of usable finger-contact samples and only when its own validity flag is set. Until then it is `null`. This is prototype telemetry, not a clinical accuracy claim.
- Fall detection, risk calculations, and alerts are out of scope for Day 2.

See [`../../docs/ble_protocol.md`](../../docs/ble_protocol.md) for BLE UUIDs, packet schema, and fragmentation rules.
