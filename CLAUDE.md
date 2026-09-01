# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Prototype for **Smart India Hackathon 2026, problem statement SIH26181** (Qualcomm Inc) — a privacy-preserving
Personal Health Companion: an ESP32 wearable streaming vitals to a Node backend that runs anomaly detection and
pushes to a Nuxt 3 PWA, with SMS escalation for critical alerts.

Two context facts that shape decisions:

- **SIH lists this PS under the Hardware category**, and Qualcomm's evaluators are edge-AI engineers. Working
  hardware and measured numbers matter more than UI polish.
- **Idea submission deadline: 20 September 2026.**

The code lives at the repository root: `backend/`, `frontend/`, `mobile/`, `firmware/`, `ml/`. `README.md`
is the user-facing doc (setup, API reference, detection-rule tables, demo script, wiring) — read it rather than
duplicating it here.

`docs/` is deliberately untracked. It holds generated PDFs and screenshots that are kept locally, so anything
committed must not depend on a file inside it.

## Commands

All commands run from the repository root.

```bash
# backend (port 4000)
cd backend && npm install && cp .env.example .env
npm run dev                    # node --watch
npm run simulate               # feed fake vitals — stands in for the ESP32
npm run simulate:demo          # scripted 5-phase demo sequence (~2.5 min)
npm run simulate -- --scenario=heatwave   # normal|exertion|hypoxia|fall|heatwave|pollution|demo

# frontend (port 3000)
cd frontend && npm install --legacy-peer-deps && cp .env.example .env
npm run dev
npm run build && npm run preview   # production build — test the service worker here, not in dev
```

**`--legacy-peer-deps` on the frontend is mandatory, not stylistic.** npm 10.9.x crashes with
`Cannot read properties of null (reading 'edgesOut')` resolving Nuxt's peer tree. Plain `npm install` fails.

**There is no test framework and no linter configured.** Don't invent `npm test` or `npm run lint` — they do not
exist. Verification is done by running the app: start backend + simulator, then curl the API or drive the UI.

Environment is **Windows / PowerShell**; a Bash tool is also available. Ports get held by stale processes — free
one with `netstat -ano | grep ":3000" | grep LISTENING` then `taskkill //F //PID <pid>`. A running `nuxt dev` or
`nuxt preview` holds `.output` and makes `npm run build` fail with `EBUSY`; stop it first.

## Architecture

Data flows one direction and the seams are deliberate:

```
ESP32 (fall detection on-device)  --POST /api/ingest-->  backend  --Socket.io-->  Nuxt PWA
                                                            |
                                                            +--> Fast2SMS/Twilio on critical
```

### Backend seams worth knowing

- **`src/store.js` is a facade over two backends.** With `DATABASE_URL` set it uses PostgreSQL (Supabase) via
  `pg`; blank or unreachable, it falls back to in-process arrays exposing the *same* methods. This exists so a
  hackathon demo cannot die on venue wifi, and matters more now the database is remote. When adding a
  persistence method, implement **both** paths — and note the in-memory path must apply column defaults by hand.
- **Every SELECT aliases `id` as `"_id"`.** The frontend was written against Mongo's `_id` and keys alerts by
  it; aliasing in SQL keeps the API contract identical rather than touching the UI.
- **`db/schema.sql` is applied automatically on boot** and is idempotent. `readings.device_id` is a foreign key
  to `devices`, so `ingest.js` must upsert the device *before* saving the reading — a first sample from an
  unknown band is otherwise rejected.
- **Supabase direct connections are IPv6-only.** Use the Session pooler URL
  (`aws-0-<region>.pooler.supabase.com:5432`); the direct one fails with `ENETUNREACH` on IPv4 networks.
- **`src/services/anomalyDetection.js` holds per-device state in a module-level Map** — sustain timers, alert
  cooldowns, and the learned resting-HR EWMA. It is not persisted. `evaluateReading(reading, ctx)` is the
  designed swap-in point for a learned model later: reading + context in, alerts out, nothing else.
- **`src/services/heatStress.js` is the project's differentiator.** It computes the NOAA Rothfusz heat index
  rather than thresholding dry-bulb temperature. Values are **clamped to 58 °C** (`HI_VALID_MAX_C`) because the
  regression extrapolates to physically absurd numbers past its fitted range — 44 °C at 65 % RH "computes" to
  ~67 °C. Do not remove the clamp.
- **Alerts are emitted twice, on purpose.** `alert:triggered` fires the instant a rule matches; `alert:updated`
  follows once the SMS attempt resolves, carrying delivery outcome. Blocking the alert on a third-party SMS API
  would delay the thing that matters. Any new alert-mutating path must emit the update too.
- **Two independent cooldowns**: alerts 60 s per type (`ALERT_COOLDOWN_MS`), SMS 5 min (`SMS_COOLDOWN_MS`). When
  an SMS is suppressed the alert records *why* in `smsNote` and the UI shows it — a held SMS must never look like
  a silent failure. Re-running a demo inside those windows is the usual cause of "it didn't fire"; clear with
  `POST /api/demo/reset`.
- **`src/routes/demo.js` is stage scaffolding**, isolated so it can be dropped with one `app.use()` line. It
  forces ambient conditions (`{"preset":"heatwave"}`) and resets detector state.

### Frontend seams worth knowing

- **`composables/useHealth.ts` owns all shared state** via `useState`, so the socket survives page navigation.
  `start()` is called once from `layouts/default.vue`. Pages read from it; they don't open their own sockets.
- **`nuxt.config.ts` must keep `navigateFallback: null`.** `@vite-pwa/nuxt` **defaults it to `'/'`**, which makes
  the service worker answer every navigation with the home page's HTML — so `/history` and `/alerts` silently
  render the live dashboard on refresh or deep link. Omitting the key is not enough; it has to be explicitly
  nulled. Verify after any PWA change: `grep -o "NavigationRoute" .output/public/sw.js` must find nothing.
- **Icons are `components/AppIcon.vue`, never emoji** — 24px grid, 1.75 stroke, `currentColor`. A name not in its
  `PATHS` map renders an empty SVG with no error, so check names when adding one.
- **Charts must not plot samples where `signalOk === false`.** The dashboard greys those out as untrustworthy;
  `pages/history.vue` blanks them via its `cleaned` computed so the two views agree.
- Visual system is documented in the header comment of `assets/css/main.css` — clinical-instrument direction,
  IBM Plex Sans/Mono, colour reserved for signal. Follow it rather than introducing new palette values.

### The learned model

`ml/` trains an autoencoder on the **BIDMC** dataset (PhysioNet, open access) — real HR and SpO2 from ICU
patients. Pipeline: `prepare_data.py` -> `train.py` -> `export_weights.py`, which writes
`backend/src/ml/model.json`.

- **The model is optional.** A clone with no `model.json` boots, runs every rule, and reports `mlScore: null`.
  `services/mlDetector.js` degrades to "no opinion" rather than throwing. Never make the rules depend on it.
- **Features are HR + SpO2 only** because that is what the ESP32 produces. BIDMC also has respiration rate
  and it would improve reconstruction, but a model needing a sensor we do not have is undeployable. Keep
  training and inference features identical.
- **Splits are by subject, never random** — consecutive windows from one patient are near-duplicates, and a
  random split inflates every metric. The threshold is chosen on validation, never test.
- **Inference is hand-written JS** (`backend/src/ml/anomalyModel.js`), not ONNX, to avoid a ~2 MB WASM
  download in an offline-first PWA and to keep a path to a C array on the MCU. `ml/test_inference_parity.py`
  proves the JS forward pass matches numpy — run it after touching either side.
- The model never suppresses a rule; it adds `ml_anomaly` (warning) only on a large sustained excursion
  (`ML_ALERT_RATIO`), because it was trained on resting physiology and scores exertion as unusual.

### Firmware

`firmware/esp32_sensor_node/` — credentials go in `config.h` (gitignored; copy from `config.example.h`).
Fall detection runs **on-device** (free fall → impact → 2 s stillness) because it needs the accelerometer at
~50 Hz and streaming that over wifi would flatten the battery. The board decides; the server sees the verdict.
The firmware has **not been verified against physical sensors** — it is written but untested on hardware.

`firmware/BRINGUP.md` is the beginner-facing hardware guide (BOM, wiring table, safety), and
`firmware/bringup/t1..t7` are staged Arduino test sketches that isolate one failure domain each. When helping
with hardware problems, ask which test number last passed — that localises the fault immediately.

## Known gaps

- **Notifications don't work on Android.** `composables/useHealth.ts` uses `new Notification(...)`, which Android
  Chrome rejects for installed PWAs; it needs `ServiceWorkerRegistration.showNotification()`. The throw is caught,
  so it fails silently.
- **The app cannot run on a phone as configured.** `NUXT_PUBLIC_API_BASE` points at `localhost`, and service
  workers require a secure context — a LAN IP over plain HTTP will not register one, so there is no install
  prompt and no offline. Needs HTTPS on both ends (tunnel or deployment).
- Deliberately out of scope for this stage, listed as roadmap in the PPT: on-device ML inference, BLE mesh / LoRa
  SOS relay, real-time multilingual voice alerts.

## Screenshots

`docs/screenshots/` holds captures of the running app. `chromium-cli` is **not** available on this machine; the
working approach is `playwright-core` (installed in the scratchpad, no browser download) driving the installed
Chrome via `channel: 'chrome'`. Capture against `npm run preview`, not `npm run dev`, so the service worker is
real. Use viewport screenshots — `fullPage` renders the `position: fixed` tab bar mid-page.
