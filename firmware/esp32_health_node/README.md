# ESP32 Day 2 BLE sensor node

This is the BLE-only Day 2 firmware. It does not use Wi-Fi, a backend, or cloud services.

## Install in Arduino IDE

Select **ESP32 Dev Module** and install:

- SparkFun MAX3010x Pulse and Proximity Sensor Library
- DHT sensor library by Adafruit
- Adafruit Unified Sensor
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

## Wiring

Pins for a classic ESP32 DevKit / WROOM-32. A C3 or S3 variant has a different
pinout — run `bringup/t3_i2c_scan` before trusting this table on your board.

| Module | Module pin | ESP32 | Notes |
|---|---|---|---|
| MAX30102 | VIN / GND | 3V3 / GND | I2C `0x57` |
| | SDA / SCL | GPIO 21 / 22 | shared bus |
| MPU6050 | VCC / GND | 3V3 / GND | I2C `0x68` (`0x69` if AD0 high) |
| | SDA / SCL | GPIO 21 / 22 | shared bus |
| OLED SSD1306 | VCC / GND | 3V3 / GND | I2C `0x3C` (sometimes `0x3D`) |
| | SDA / SCL | GPIO 21 / 22 | shared bus |
| DHT22 (3-pin module) | + / − | 3V3 / GND | ambient air only, never body temperature |
| | DATA | GPIO 4 | module has its own pull-up |
| **Rain board** | VCC / GND | 3V3 / GND | comparator module (LM393) |
| | **AO** | **GPIO 34** | analog wetness — see ADC note |
| | DO | *unused* | the analog value is strictly more informative |
| **Buzzer (2-pin)** | — | **via transistor on GPIO 25** | see circuit below |

### Rain board must be on GPIO 32–39

ADC2 — which covers GPIO 0, 2, 4, 12–15 and 25–27 — shares hardware with the
radio and returns garbage whenever the radio is active. This firmware runs BLE
continuously, so ADC2 is unusable. GPIO 34 is on ADC1 and is input-only, so it
cannot be driven by mistake.

The board reads near full scale when dry and falls as water bridges its traces.
Calibrate before trusting the percentage: watch `rr` (the raw count) in the
telemetry with the board dry, then wet, and put those two numbers into
`RAIN_DRY_COUNT` and `RAIN_WET_COUNT` in `config.h`.

`rr` is transmitted alongside `rain` on purpose. A disconnected board floats at
some mid-scale value rather than reading a clean zero, so a steady mid-range
`rr` with a dry board means the sensor is unplugged, not that it is drizzling.

### Buzzer: do not wire it straight to the GPIO

A two-pin buzzer is a load, not a logic input. Sizing matters:

- a small **piezo disc** draws under ~10 mA and *can* run off a pin
- a **magnetic/electromagnetic** buzzer draws 25–30 mA, which is over the
  ESP32's 12 mA recommended per-pin current and near its 40 mA absolute maximum

Unless you have measured yours and know it is the first kind, use the
transistor. It costs one component and works for either.

```
3V3 ──────────────┬── buzzer (+)
                  │
              buzzer (−)
                  │
                  ├──────────┐
                  │          │
                  │        ┌─┴─┐  flyback diode (1N4148)
                  │        │ ▲ │  cathode to 3V3 — only needed for a
                  │        └─┬─┘  magnetic buzzer, which is inductive
                  │          │
             collector ──────┘
                  │
GPIO 25 ──[1 kΩ]── base      NPN: BC547, 2N2222 or S8050
                  │
              emitter
                  │
                 GND
```

Common ground between the ESP32 and the buzzer supply is required. The 1 kΩ
base resistor limits GPIO current to roughly 2 mA; the pin never carries the
buzzer's current.

**Passive or active?** Set `BUZZER_IS_PASSIVE` in `config.h`. A passive buzzer
is a bare piezo and needs a square wave — on a steady HIGH it clicks once and
goes silent. An active buzzer has its own oscillator and sounds on DC. If yours
only clicks with `BUZZER_IS_PASSIVE false`, it is passive; set it to `true`.
