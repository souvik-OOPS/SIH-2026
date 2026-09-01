#pragma once

// Copy this file to config.h before compiling. It is deliberately separate so
// each board's final wiring can be reviewed without changing source code.

// ESP32 Dev Module proposal approved for this prototype.
#define I2C_SDA_PIN 21
#define I2C_SCL_PIN 22
#define DHT_DATA_PIN 4

// Common 0.96-inch SSD1306 address. If the I2C scanner reports 0x3D, change
// this value. An SH1106 display needs a different display driver.
#define OLED_I2C_ADDRESS 0x3C

// The attached buzzer has two pins. Keep this false until its voltage/current
// and a transistor/MOSFET driver circuit have been confirmed.
#define ENABLE_BUZZER_DRIVER false
#define BUZZER_DRIVER_PIN 25

#define BLE_DEVICE_NAME "SwasthyaShield-Edge"
#define TELEMETRY_INTERVAL_MS 1000UL

// MAX30102 finger/contact heuristics. These are signal-contact checks, not
// a statement of measurement accuracy or a clinical calibration.
#define FINGER_IR_THRESHOLD 50000UL
#define PPG_SAMPLE_RATE_HZ 25
