# SwasthyaShield Edge — Flutter Day 1

An Android-first offline dashboard for the SIH26181 prototype. It starts in
deterministic Replay mode and can switch to the Day 2 ESP32 BLE source from
the Bluetooth icon in the top app bar. The UI depends only on the
`TelemetrySource` abstraction, not on either implementation.

## Run

From this directory:

```powershell
flutter pub get
flutter run
```

For live hardware telemetry, upload the firmware in
[`../firmware/esp32_health_node`](../firmware/esp32_health_node), turn on the
ESP32, then tap the Bluetooth scan icon. Approve Android's Nearby devices
permission. The app filters for the documented SwasthyaShield service UUID,
not arbitrary nearby devices. Use the replay icon to return to the
hardware-free demo at any time.

Open the developer icon in the top-right corner and select **Normal**, **Heat Warning**, **Fall + Non-response**, or **Bad Signal**. The app loops the selected fixture continuously; the selector also provides 1×, 2×, and 4× playback plus restart.

## Verify

```powershell
flutter test
flutter analyze
```

## Architecture seam

`DashboardScreen` receives `TelemetrySession`, which only depends on the
`TelemetrySource` and `DemoTelemetryControls` interfaces. `ReplayTelemetrySource`
and `BleTelemetrySource` are composed in `app.dart`; neither is referenced by
UI widgets. BLE fragment reassembly and permission handling live below the
same source contract.
