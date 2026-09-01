# Day 2 hardware wiring — proposed, pending human review

> **Do not power this circuit from this document until the review checklist at the end is confirmed.** These are proposed connections for a classic ESP32 DevKit / ESP32-WROOM-style board with exposed GPIO 21, 22, 4, and 25. They are **not** a pinout for every ESP32-family board (for example, C3/S3 variants may differ).

## Safety rules

- Disconnect USB power before adding, removing, or moving wires.
- Use a **common GND** for the ESP32 and every module.
- Use the ESP32's **3V3 rail** for the proposed setup. Do not connect an unknown module to 5 V.
- Do not use ESP32 boot/strapping pins GPIO 0, 2, 5, 12, or 15 for these peripherals. Do not use GPIO 34–39 for outputs; they are input-only on the original ESP32.
- Bluetooth uses the ESP32 radio; it needs no external GPIO wiring.

## Proposed ESP32 pin allocation

| ESP32 GPIO | Proposed role | Notes |
|---|---|---|
| 21 | I²C SDA | Shared by MAX30102, MPU6050, and OLED. Generic ESP32 default, but firmware will explicitly configure it. |
| 22 | I²C SCL | Shared by MAX30102, MPU6050, and OLED. Generic ESP32 default, but firmware will explicitly configure it. |
| 4 | DHT22 data | Existing project convention. Verify that GPIO 4 is physically exposed and free on the exact board. |
| 25 | Reserved buzzer-driver control | The confirmed two-pin buzzer must **not** connect directly to this GPIO. GPIO 25 may later control a transistor driver after the buzzer's voltage/current are confirmed. |

## Connection table

| Module | Module pin | Proposed ESP32 connection | Expected voltage / address | Review notes |
|---|---|---|---|---|
| MAX30102 breakout | VIN / VCC | 3V3 | Supply at 3.3 V; I²C usually `0x57` | Common breakouts vary. Use the board's VCC/VIN label and do not assume the bare MAX30102 IC has the same supply requirements as the breakout. |
|  | GND | GND | — | Required common ground. |
|  | SDA | GPIO 21 | 3.3 V I²C logic | Shared I²C bus. |
|  | SCL | GPIO 22 | 3.3 V I²C logic | Shared I²C bus. |
|  | INT | Leave unconnected for Day 2 | — | Polling is sufficient for this milestone. |
| MPU6050 / GY-521 | VCC | 3V3 | Supply at 3.3 V; I²C `0x68` normally, `0x69` if AD0 is high | Some GY-521 boards accept 5 V at VCC, but 3.3 V keeps I²C logic safe. |
|  | GND | GND | — | Required common ground. |
|  | SDA | GPIO 21 | 3.3 V I²C logic | Shared I²C bus. |
|  | SCL | GPIO 22 | 3.3 V I²C logic | Shared I²C bus. |
|  | INT | Leave unconnected for Day 2 | — | Day 2 samples by polling; no interrupt is required. |
| 0.96-inch OLED | VCC / VDD | 3V3 | Common SSD1306 displays: `0x3C`; sometimes `0x3D` | Confirm the controller is SSD1306 or SH1106 and check the board's stated supply range. |
|  | GND | GND | — | Required common ground. |
|  | SDA | GPIO 21 | 3.3 V I²C logic | Shared I²C bus. |
|  | SCL | GPIO 22 | 3.3 V I²C logic | Shared I²C bus. |
| DHT22 **module** | VCC / `+` | 3V3 | 3.3 V single-wire data; no I²C address | This is an **ambient** temperature and humidity sensor, not a body-temperature sensor. |
|  | GND / `-` | GND | — | Required common ground. |
|  | DATA / OUT | GPIO 4 | 3.3 V logic | A bare 4-pin DHT22 needs a 4.7–10 kΩ pull-up from DATA to 3V3. A 3-pin module commonly includes it; confirm before adding a second resistor. |
| Two-pin buzzer **(confirmed)** | `+` / either lead | **Do not connect to GPIO or 3V3 yet** | Voltage/current still required | A two-pin buzzer has no logic input. Its supply must be switched through an appropriate transistor/MOSFET driver and common ground. |
|  | `-` / other lead | **Do not connect to GPIO or GND yet** | — | The final polarity/driver circuit depends on whether it is an active or passive buzzer and its rating. |
| Future driver control | Transistor/MOSFET control input | GPIO 25 through a reviewed resistor/driver circuit | 3.3 V GPIO logic | Firmware can expose `triggerBuzzer(...)` once the electrical driver is agreed. |

## I²C bus expectations

Three modules share the same two wires: connect **all SDA pins together** to GPIO 21 and **all SCL pins together** to GPIO 22. This is normal I²C wiring; each device has its own address.

Expected scan results after wiring:

| Device | Normal address | Valid alternate / caveat |
|---|---:|---|
| MAX30102 | `0x57` | If absent, stop and verify VCC, GND, SDA/SCL, and module solder joints. |
| MPU6050 | `0x68` | `0x69` when AD0 is pulled high. |
| OLED | `0x3C` | `0x3D` is also common; an SH1106 may share the address but needs a different display driver. |

The DHT22 is not on I²C and will not appear in an I²C scan. The buzzer is a GPIO output and will not appear either.

Most breakout boards include I²C pull-up resistors. Do not add extra pull-ups unless an I²C scan shows an actual bus problem and the module boards have been inspected first; too many parallel pull-ups can make the bus unreliable.

## Bring-up sequence after approval

1. With USB unplugged, connect only ESP32, MAX30102, MPU6050, and OLED power/GND/I²C wires.
2. Recheck that SDA is not crossed with SCL and that every VCC connection goes to 3V3.
3. Power through USB and run an I²C scanner. Record every discovered address before proceeding.
4. Power off, add DHT22, then test its ambient temperature/humidity reading. `NaN` is a sensor-read failure, not a valid measurement.
5. Keep the confirmed two-pin buzzer disconnected until its voltage/current and a safe driver circuit are agreed.
6. Only after each local diagnostic passes, upload the combined BLE firmware.

## Must be confirmed before firmware pins are final

- Exact ESP32 board name and a photo or pin-label confirmation showing GPIO 21, 22, 4, and 25.
- MAX30102 breakout labels and its stated VCC/VIN operating range.
- OLED labels/controller (SSD1306 or SH1106) and stated VCC range.
- DHT22 type: 3-pin module or bare 4-pin sensor.
- Buzzer type: confirmed two-pin part; provide its operating voltage/current and whether it is active or passive before a driver circuit is selected.

## Sources used for the proposal

- [Arduino-ESP32 I²C API](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/i2c.html) — GPIO 21/22 are generic ESP32 defaults, but the API supports explicit pin selection.
- [Espressif ESP32 GPIO documentation](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/gpio.html) — pin capabilities and boot/strapping-pin cautions.
