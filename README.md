<div align="center">

# 🫀 Personal Health Companion

**Smart India Hackathon 2026 · Problem Statement SIH26181 (Qualcomm Inc.)**
Theme: MedTech / BioTech / HealthTech · Category: Hardware

A privacy-preserving wearable health companion that monitors a wearer's vitals in real time, cross-references
them against environmental conditions, and raises early warnings — built for resilience during heatwaves,
floods, and pollution events.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Node](https://img.shields.io/badge/Node.js-%3E%3D20-339933?logo=node.js&logoColor=white)](backend/package.json)
[![Nuxt](https://img.shields.io/badge/Nuxt-3-00DC82?logo=nuxt.js&logoColor=white)](frontend/package.json)
[![Flutter](https://img.shields.io/badge/Flutter-Edge%20App-02569B?logo=flutter&logoColor=white)](mobile/pubspec.yaml)
[![ESP32](https://img.shields.io/badge/Firmware-ESP32-E7352C?logo=espressif&logoColor=white)](firmware/esp32_sensor_node)
[![PyTorch](https://img.shields.io/badge/ML-PyTorch%20Autoencoder-EE4C2C?logo=pytorch&logoColor=white)](ml/train.py)
[![Tests](https://img.shields.io/badge/backend%20tests-92%20passing-brightgreen)](backend/test)

[Overview](#what-this-prototype-does) ·
[Quick Start](#quick-start) ·
[Architecture](#architecture) ·
[API Reference](#api-reference) ·
[Testing](#testing--verification) ·
[Contributing](#contributing) ·
[License](#license)

</div>

---

## Table of Contents

- [What this prototype does](#what-this-prototype-does)
- [Key capabilities that go past plain thresholds](#key-capabilities-that-go-past-plain-thresholds)
- [Quick start](#quick-start)
- [Architecture](#architecture)
- [API Reference](#api-reference)
- [Detection & Safety Rules](#detection--safety-rules)
- [Testing & Verification](#testing--verification)
- [Repository Layout](#repository-layout)
- [Firmware Setup](#firmware-setup)
- [Tech Stack](#tech-stack)
- [Known Limitations](#known-limitations)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Team](#team)
- [Acknowledgements](#acknowledgements)
- [License](#license)

---

## What this prototype does

| | |
|---|---|
| **Senses** | Heart rate + SpO₂ (MAX30102), ambient temperature + humidity (DHT22), motion and falls (MPU6050), all on an ESP32 |
| **Detects** | Tachycardia, bradycardia, hypoxia, multi-stage falls, heat stress, poor air quality, excursions above personal resting rate |
| **Safety Loop** | "Are you okay?" check-in countdown after fall detection, escalating to emergency SMS if unanswered |
| **Warns** | Live dashboard banner → browser notification → SMS to an emergency contact for critical alerts |
| **Correlates** | Physiological strain against apparent temperature, AQI, and official NDMA SACHET disaster alert feeds |
| **Learns** | An on-device autoencoder trained on real ICU patient vitals scores each 30 s window against normal physiology |
| **Runs** | Installable PWA, works offline against cached readings; comprehensive 92-test automated verification suite |

### Key capabilities that go past plain thresholds

**Heat index, not dry-bulb temperature.** A naive rule (`temp > 40 && humidity > 60`) misses the physiology:
**38 °C at 80 % RH is more dangerous than 42 °C at 20 % RH**, because sweat cannot evaporate. The backend computes
the NOAA/NWS Rothfusz heat index and bands it (Safe → Caution → Extreme caution → Danger → Extreme danger).
Verified against NOAA's published table: 100 °F at 65 % RH → 135.9 °F (table says 136 °F). Values are clamped at
58 °C, the ceiling of the published chart, and flagged when the inputs fall outside the regression's fitted range.

**A personalised baseline.** The engine learns each wearer's resting heart rate from their own at-rest samples
(slow EWMA, guarded against PPG glitches) and expresses strain as a fraction of *their* reserve, rather than
comparing everyone to the same number. Heat-stress alerts require the environment to be dangerous **and** the body
to be responding to it.

**A model trained on real patients.** An autoencoder learns healthy physiology from the BIDMC dataset
(PhysioNet — real HR and SpO₂ from ICU patients) and scores how far each 30-second window sits from normal.
Splits are subject-wise and stratified, the threshold is chosen on validation, and inference is ~25 lines of
dependency-free JavaScript so it runs in the browser with no cloud call and no WASM download. It answers
*"this does not look like your normal"* — never *"you have condition X."*

**Resilient Fall Check-in & Emergency Packet.** When a candidate fall occurs, an interactive check-in countdown
is triggered. If the wearer presses "I'M OK", the incident resolves quietly. If unanswered within 30 seconds, it
escalates to emergency contacts with an offline-generated responder summary packet carrying vital trends, event
context, and location.

**Official Disaster Awareness (NDMA SACHET).** Integrates official government disaster warnings (heatwaves, cyclones,
floods) with radius-based distance matching to provide contextual awareness alongside physiological telemetry.

---

## Quick start

Two terminals. No hardware and no credentials needed — the simulator stands in for the ESP32, and SMS defaults
to a console dry-run.

```bash
# terminal 1 — backend
cd backend
npm install
cp .env.example .env
npm run dev                 # http://localhost:4000
npm test                    # run the automated test suite (92 tests)

# terminal 2 — frontend
cd frontend
npm install --legacy-peer-deps
cp .env.example .env
npm run dev                 # http://localhost:3000
```

To build and preview the production PWA bundle:

```bash
cd frontend
npm run build
npm run preview             # or: node .output/server/index.mjs
```

Then, in a third terminal, feed it data:

```bash
cd backend
npm run simulate            # steady normal vitals
npm run simulate:demo       # the full scripted demo sequence
```

> **`--legacy-peer-deps` on the frontend is required, not optional.** npm 10.9.x crashes with
> `Cannot read properties of null (reading 'edgesOut')` while resolving Nuxt's peer tree. The flag skips the
> code path that crashes; the install is otherwise identical.

### Database (Supabase)

The backend uses **PostgreSQL**. Put your connection string in `backend/.env` as `DATABASE_URL` and the
schema in `db/schema.sql` is applied automatically on first boot — nothing to run by hand.

> **Use the Session pooler string, not the direct one.** Supabase's direct connection
> (`db.<ref>.supabase.co:5432`) is **IPv6-only**, and most home and college networks are IPv4, so it fails
> with `ENETUNREACH`. In the Supabase dashboard go to **Project Settings → Database → Connection string →
> Session pooler**, which looks like
> `postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres`.

If the database is unreachable the backend logs the reason and falls back to the in-memory store rather than
failing to start. `GET /api/health` reports which backend is live — check it before a demo.

### Optional configuration

Everything below is optional — the app runs fully without any of it.

| `.env` key | Effect when set |
|---|---|
| `DATABASE_URL` | Persists readings and alerts to PostgreSQL (Supabase). **Blank = in-memory store**, which still works end to end but loses data on restart. |
| `OPENWEATHER_API_KEY` | Adds live AQI / PM2.5 and a weather fallback when the device has no DHT22. |
| `DISASTER_ENABLED` | Enables NDMA SACHET disaster alert feed integration (`true` by default). |
| `SMS_PROVIDER` | `console` (default, prints to terminal) · `fast2sms` · `twilio` |
| `EMERGENCY_CONTACT` | Number that receives critical alerts. |
| `DEVICE_API_KEY` | Shared secret the ESP32 must present. Blank disables the check. |

---

## Architecture

```
┌──────────────────────────────────────────┐
│  ESP32 + MAX30102 + DHT22 + MPU6050      │
│  · samples PPG at 25 Hz                  │
│  · reads accelerometer at 50 Hz          │
│  · detects falls ON-DEVICE               │
└──────────────────┬───────────────────────┘
                   │  HTTP POST /api/ingest  (WiFi, JSON, x-api-key)
                   ▼
┌──────────────────────────────────────────┐
│  Node.js / Express backend               │
│  · normalise + range-check every field   │
│  · learn resting-HR baseline             │
│  · heat index + strain + AQI assessment  │
│  · multi-stage fall & check-in safety    │
│  · NDMA SACHET disaster context parser   │
│  · rule engine w/ sustain + cooldown     │
│  · Postgres (or in-memory fallback)      │
│  · Fast2SMS / Twilio on critical         │
└──────┬──────────────────────┬────────────┘
       │ Socket.io            │ REST
       ▼                      ▼
┌──────────────────────────────────────────┐
│  Nuxt 3 PWA                              │
│  · live vitals + heat/strain meters      │
│  · interactive fall check-in dialog      │
│  · trend charts (Chart.js)               │
│  · alert log with acknowledge            │
│  · emergency packet & privacy controls   │
│  · installable, offline-cached           │
└──────────────────────────────────────────┘
```

Fall detection runs on-device on the ESP32 (~50 Hz sampling) and is corroborated by the backend's multi-stage state machine (Free fall → Impact → Orientation → Stillness).

---

## API Reference

### Telemetry & Monitoring
| Method | Route | Purpose |
|---|---|---|
| `POST` | `/api/ingest` | Sensor sample from wearable/simulator |
| `GET` | `/api/history/:deviceId?minutes=60&limit=600` | Readings for trend charts |
| `GET` | `/api/alerts/:deviceId` | Alert history log |
| `POST` | `/api/alerts/:alertId/ack` | Acknowledge an alert |
| `GET` | `/api/devices` · `/api/devices/:id` | Registered wearers, thresholds, baseline info |
| `PUT` | `/api/devices/:id` | Update profile (`elderly`, `outdoor_worker`, `chronic_condition`), age, contacts |
| `GET` | `/api/health` | Backend status, store mode, SMS/weather/ML liveness |

### Safety Loop & Privacy
| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/safety/:deviceId/check-in` | Current fall check-in countdown status |
| `POST` | `/api/safety/:deviceId/respond-ok` | Wearer presses "I'M OK" to resolve check-in |
| `POST` | `/api/safety/:deviceId/clear-check-in` | Dismiss closed incident |
| `GET` | `/api/safety/:deviceId/emergency-packet` | Compact responder summary packet with vital trends & risk |
| `GET` | `/api/safety/:deviceId/privacy` | Stored data transparency and consent summary |
| `POST` | `/api/safety/:deviceId/clear-baseline` | Clear learned resting HR baseline |
| `DELETE` | `/api/safety/:deviceId/data?confirm=true` | Erase stored telemetry and alerts (optional `&includeProfile=true`) |
| `GET` | `/api/safety/config` | Safety thresholds in force (fall acceleration, stillness windows) |

### Disaster Context
| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/disaster-context` | Active NDMA SACHET alerts near the wearer (`?lat=&lon=&radiusKm=`) |
| `POST` | `/api/disaster-context/refresh` | Force refresh of the government feed |

### Demo Controls (`routes/demo.js`)
| Method | Route | Purpose |
|---|---|---|
| `POST` | `/api/demo/env` | Force ambient preset: `{"preset":"heatwave"}` (also `pollution`, `flood`, `normal`) |
| `DELETE` | `/api/demo/env` | Revert to live sensor / OpenWeather data |
| `POST` | `/api/demo/reset/:deviceId` | Clear baseline, sustain timers and cooldowns |

---

## Detection & Safety Rules

| Alert | Severity | Condition |
|---|---|---|
| `hypoxia` | critical | SpO₂ below critical bound (<88%) — fires immediately |
| `hypoxia` | critical | SpO₂ below warning bound (<92%), held 30 s |
| `fall` | critical | Free fall → impact → orientation change → stillness (or device report) |
| `fall_no_response` | critical | Unanswered check-in after 30 s countdown |
| `tachycardia` | warning | HR above ceiling in force (age-adjusted via Tanaka), held 30 s |
| `bradycardia` | warning | HR below profile bound (<50 bpm), held 30 s |
| `hr_above_baseline` | warning | At rest, HR >30 bpm above learned resting baseline for 30 s |
| `heat_stress` | warning/critical | Heat-index band is dangerous **and** cardiovascular strain ≥45% of reserve |
| `air_quality` | warning | OpenWeather AQI ≥5, or PM2.5 >120 µg/m³ |
| `ml_anomaly` | warning | Learned model reconstruction error ≥1.6× normal threshold for 30 s |

---

## Testing & Verification

Comprehensive automated test suites cover all modules:

```bash
# Backend unit, service, route, and simulator scenario tests (92 tests)
cd backend && npm test

# ML inference parity and edge-case tests
cd ml
python test_inference_parity.py
python test_inference_robustness.py

# Frontend production build & service worker validation
cd frontend
npm run build
```

---

## Repository Layout

```
health-companion/
├── backend/
│   ├── db/schema.sql                PostgreSQL tables (applied automatically on boot)
│   ├── src/
│   │   ├── routes/                  ingest, history, alerts, devices, safety, disaster, demo
│   │   ├── services/
│   │   │   ├── anomalyDetection.js  Vitals rules, EWMA resting-HR baseline learning
│   │   │   ├── heatStress.js        NOAA Rothfusz heat index regression & air quality
│   │   │   ├── fallDetection.js     Multi-stage fall detection state machine
│   │   │   ├── nonResponse.js       "Are you okay?" check-in & countdown workflow
│   │   │   ├── riskEngine.js        Deterministic multi-factor risk assessment
│   │   │   ├── emergencyPacket.js   Offline responder summary generation
│   │   │   ├── disaster/            NDMA SACHET parser, geospatial radius filtering
│   │   │   ├── weatherService.js    OpenWeather API client & mock overrides
│   │   │   ├── smsService.js        Fast2SMS / Twilio dispatch w/ cooldowns
│   │   │   └── mlDetector.js        Buffer manager for learned model inference
│   │   ├── ml/                      anomalyModel.js (forward pass) + model.json
│   │   ├── store.js                 PostgreSQL ⇄ In-memory storage facade
│   │   ├── simulator.js             Interactive vitals generator (7 scenarios)
│   │   └── server.js                Express app & Socket.io server
│   └── test/                        Automated test suite (92 tests across 39 suites)
├── frontend/
│   ├── pages/                       index (live) · history (trends) · alerts · privacy
│   ├── components/                  VitalTile · AlertBanner · TrendChart · AppIcon
│   ├── composables/                 useHealth.ts (Socket.io + shared state)
│   └── nuxt.config.ts               PWA manifest, workbox caching rules
├── ml/                              Autoencoder training pipeline (PyTorch)
│   ├── prepare_data.py              BIDMC ICU dataset preprocessing
│   ├── train.py                     Model training with early stopping
│   ├── export_weights.py            Weights exporter to backend/src/ml/model.json
│   ├── test_inference_parity.py     Python vs JS parity verification
│   └── test_inference_robustness.py Multi-seed and edge-case robustness tests
├── mobile/                          Flutter edge application
│   ├── lib/                         Mobile dashboard, BLE packet assembler, risk engine
│   └── test/                        Replay scenarios and unit tests
└── firmware/
    ├── BRINGUP.md                   Beginner hardware & sensor wiring guide
    ├── bringup/                     t1–t7 staged hardware test sketches
    └── esp32_sensor_node/           Main sensor node sketch + config.h
```

---

## Firmware Setup

**New to hardware? Start with [`firmware/BRINGUP.md`](firmware/BRINGUP.md)** — a step-by-step guide: what to buy, how to wire it, and seven staged test sketches in `firmware/bringup/` that prove one thing each (board alive → WiFi → I²C wiring → each sensor → backend reachable) before running the full firmware.

Copy `config.example.h` to `config.h` and set your WiFi credentials and your laptop's **LAN IP** (not `localhost` — the ESP32 must reach it across the network).

Required Arduino libraries:
- SparkFun MAX3010x Pulse and Proximity Sensor Library
- DHT sensor library (Adafruit) + Adafruit Unified Sensor
- Adafruit MPU6050

Wiring: MAX30102 and MPU6050 share I2C on GPIO21 (SDA) / GPIO22 (SCL); DHT22 data on GPIO4 with a 10 kΩ pull-up.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Firmware | ESP32, Arduino framework, MAX30102, DHT22, MPU6050 |
| Backend | Node.js ≥20, Express, Socket.io, PostgreSQL (Supabase) |
| Frontend | Nuxt 3, Vue 3, Chart.js, Vite PWA |
| Mobile | Flutter (edge/offline companion app) |
| Machine Learning | PyTorch (training), dependency-free JS (browser inference) |
| Alerts | Fast2SMS / Twilio, NDMA SACHET disaster feed, OpenWeather API |

---

## Known Limitations

- MAX30102 SpO₂ is susceptible to motion artifacts; the firmware sets `signalOk: false` when disconnected, and the dashboard greys out those samples.
- DHT22 measures temperature and humidity only — **it cannot measure PM2.5**. Air-quality alerts use OpenWeather API data or a physical particulate sensor.
- In-memory fallback store caps at 5,000 readings and 500 alerts (lost on restart). Use PostgreSQL/Supabase for persistent storage.
- The PWA requires HTTPS or `localhost` to register service workers and enable offline install prompts.
- Browser notification permissions on mobile devices must be granted explicitly through the browser settings.

---

## Roadmap

- [ ] Multi-device family/caregiver dashboards
- [ ] Bluetooth Low Energy companion pairing for the mobile app
- [ ] On-device (ESP32) inference for the anomaly model
- [ ] Localisation for regional languages and low-bandwidth SMS fallback
- [ ] Clinician-facing export (PDF/CSV) of vitals and alert history

---

## Contributing

Contributions, issues and feature requests are welcome.

1. Fork the repository and create your branch from `main`: `git checkout -b feature/your-feature`
2. Make your changes, following the existing code style in each subproject (`backend`, `frontend`, `ml`, `mobile`, `firmware`)
3. Add or update tests where relevant (`npm test` in `backend`, `python test_*.py` in `ml`, `flutter test` in `mobile`)
4. Commit with a clear message and open a pull request describing the change and why it's needed

Please open an issue first for significant changes so the approach can be discussed before implementation.

---

## Team

Built for **Smart India Hackathon 2026**, Problem Statement **SIH26181** (Qualcomm Inc.).

See [Contributors](../../graphs/contributors) for everyone who has worked on this repository.

---

## Acknowledgements

- [NOAA/NWS](https://www.weather.gov/safety/heat-index) — Rothfusz heat index regression
- [PhysioNet BIDMC dataset](https://physionet.org/content/bidmc/1.0.0/) — real ICU patient vitals used to train the anomaly model
- [NDMA SACHET](https://sachet.ndma.gov.in/) — official Indian disaster alert feed
- [OpenWeather](https://openweathermap.org/) — live air quality and weather fallback data

