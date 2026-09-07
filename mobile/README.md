# SwasthyaShield Edge — Flutter

The primary Android app: BLE telemetry, on-device anomaly detection, explainable
risk, background monitoring, local notifications/history, and an English/Hindi
offline assistant. First launch starts in labelled Replay mode.

## Run

From this directory:

```powershell
flutter pub get
flutter run
```

For live hardware telemetry, upload the firmware in
[`../firmware/esp32_health_node`](../firmware/esp32_health_node), turn on the
ESP32, then tap the Bluetooth scan icon. Approve Android's Nearby devices
and Notifications permissions. The app filters for the documented service UUID,
not arbitrary nearby devices. Use the replay icon to return to the
hardware-free demo at any time.

Open the developer icon in the top-right corner and select **Normal**, **Heat Warning**, **Fall + Non-response**, or **Bad Signal**. The app loops the selected fixture continuously; the selector also provides 1×, 2×, and 4× playback plus restart.

## Verify

```powershell
flutter test
flutter analyze --no-fatal-infos
flutter build apk --debug
```

## Architecture seam

`DashboardScreen` receives `TelemetrySession`, which only depends on the
`TelemetrySource` and `DemoTelemetryControls` interfaces. `ReplayTelemetrySource`
and `BleTelemetrySource` are composed in `app.dart`; neither is referenced by
UI widgets. BLE fragment reassembly and permission handling live below the
same source contract.

## Background monitoring and history

Connecting from Live starts an Android `connectedDevice` foreground service.
The persistent notification confirms monitoring is active while another app is
visible or the screen is locked. **Stop monitoring** in that notification, or
Settings, disconnects the wearable. Force-stop and phone restart end monitoring;
reopen to resume. Bluetooth, permissions, and OEM battery restrictions still apply.

Activity has **Trends**, **Alerts**, and **Readings** tabs. Select 15m, 1h, 6h,
24h, or 7d, and choose Wearable or Demo; their records stay separate. Tap HR,
SpO2, air-temperature, and humidity charts to inspect an interval. Statistics
use all usable samples in the selected period. Lines show interval averages;
missing/unreliable samples and recording interruptions break the line. Charts
are aggregated in SQLite to keep long histories small on the phone.

Alerts can be marked reviewed. The raw Readings tab shows the latest 720 samples
within the selected source and period; the trend statistics include the full period.
The local journal retains seven days of 10-second samples and 500 alerts.
Unreliable HR/SpO2 are stored as gaps. Settings can delete the journal. Android
cloud backup is disabled; no history is uploaded by the app.

### Emergency summary

Use the summary icon in Activity or **Live → Emergency → Preview emergency
summary**. The preview includes a timestamp, data freshness, signal quality,
current/last-computed risk, usable readings, recent ten-minute statistics, and
recent alerts. It stays fixed while you review it; refresh captures a new snapshot.
Stale/unreliable current vitals are withheld, and historical values are labelled.
Demo summaries carry an explicit test label. Location is not collected.

**Share snapshot** opens Android's share sheet. You choose the destination and
complete the send there. Preparing/opening the summary sends nothing automatically
and does not establish delivery. Sharing exports the displayed health information
to the app you choose; ordinary monitoring still keeps it on this phone.

Prototype notification defaults:

| Trigger | Delay |
|---|---|
| Usable HR >120 or <50 bpm | 30 seconds |
| Usable SpO2 <92% and >88% | 30 seconds |
| Usable SpO2 ≤88% | Immediate |
| Risk WARNING / CRITICAL | 30 seconds / immediate |
| Fall / unanswered check-in | Immediate at each workflow stage |
| Stale/disconnected readings | 15 seconds |
| Unusable pulse signal | 45 seconds |

Bad contact and stale data cannot trigger vital alarms. Same-type alerts have a
five-minute cooldown within a monitoring session; a more severe type can still
appear immediately. Restarting monitoring resets cooldowns. Blocked notifications
remain in Activity. Android notification and Do Not Disturb settings control sound.
These thresholds are prototype defaults, not a clinical diagnosis.

Replay does not post system notifications unless **Settings → Demo notifications**
is enabled; those alerts are labelled DEMO. The notification pipeline sends no
SMS. SMS remains an explicit action to configured contacts and needs cellular service.

## Optional local language model

The bundled guide works immediately, without downloads: 36 English/Hindi entries,
ranked retrieval, source metadata, and deterministic urgent/current-state answers.
For actual local generation on ARM64 Android:

```powershell
python tool/prepare_local_llm.py
flutter build apk --debug
```

The script fetches pinned llama.cpp source and official **Qwen3-0.6B Q8_0 GGUF**
(approximately 639 MB) into ignored `vendor/`. On the phone, use **Assistant →
Diagnostics → Import GGUF**, select that model and wait for initialization.
The model is outside the APK, in private app storage. After import, generation
needs no internet. A fresh install without it uses the guide.

The native runtime uses two CPU threads, a 2,048-token context and up to 160 output
tokens. Diagnostics reports measured timing and actual model metadata. Long prompts,
invalid models, and timeouts fall back to the guide. General generated explanations
can still be wrong. Risk, alerts, and SMS are independent of model output.

`QualcommQwenEngine` is a legacy Dart name; the implemented backend is llama.cpp CPU,
with no NPU claim. The llama.cpp MIT notice is in Android assets. Preserve the
[official Qwen Apache-2.0 model license/card](https://huggingface.co/Qwen/Qwen3-0.6B-GGUF)
when distributing model files.

See [the implementation review](IMPLEMENTATION_REVIEW.md) for the Flutter/PWA
comparison, SIH priorities, device results, and remaining limitations.
