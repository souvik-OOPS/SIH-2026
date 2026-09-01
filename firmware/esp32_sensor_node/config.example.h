#pragma once
// Copy this file to config.h and fill in your values. config.h is gitignored.

// ---- WiFi ----
#define WIFI_SSID       "YourNetwork"
#define WIFI_PASSWORD   "YourPassword"

// ---- Backend ----
// Use your laptop's LAN IP, not localhost — the ESP32 has to reach it over WiFi.
// Find it with `ipconfig` (Windows) or `ifconfig` (macOS/Linux).
#define SERVER_URL      "http://192.168.1.100:4000/api/ingest"
#define DEVICE_ID       "band-001"
#define DEVICE_API_KEY  "sih26181-dev-key"   // must match the backend .env

// ---- Timing ----
#define SEND_INTERVAL_MS   1000   // 1 Hz: matches the ML model's 30-second input window
#define PPG_SAMPLE_HZ      25     // MAX30102 sampling rate for SpO2

// ---- Pins ----
#define DHT_PIN         4
#define DHT_TYPE        DHT22     // or DHT11
// MAX30102 and MPU6050 share the I2C bus:
#define I2C_SDA         21
#define I2C_SCL         22
