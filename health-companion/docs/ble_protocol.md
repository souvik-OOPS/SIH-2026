# SwasthyaShield Edge BLE telemetry protocol — Day 2

## GATT contract

| Item | Value |
|---|---|
| Advertising name | `SwasthyaShield-Edge` |
| Service UUID | `9d5a0001-9d36-4b60-a680-59ab9204d001` |
| Telemetry characteristic UUID | `9d5a0002-9d36-4b60-a680-59ab9204d001` |
| Characteristic properties | Notify, Read |
| Telemetry rate | 1 frame per second |
| Transport | ASCII JSON, explicitly fragmented into BLE notifications |

The ESP32 requests MTU 185 and the Android client may request a larger MTU, but the protocol is correct even when the default ATT payload is only 20 bytes. No notification is assumed to contain a complete JSON document.

## JSON document

After reassembly, every frame is one compact JSON document. Unknown, unavailable, or invalid values are represented by `null`, never a substitute value.

```json
{"v":1,"u":18342,"hr":78.4,"o2":null,"t":31.4,"h":67.0,"ax":0.10,"ay":0.00,"az":0.98,"gx":1.2,"gy":0.4,"gz":0.3,"q":92,"f":1}
```

| Key | Meaning | Unit / valid range |
|---|---|---|
| `v` | Protocol version | `1` |
| `u` | ESP32 monotonic uptime | milliseconds; not wall-clock time |
| `hr` | Heart-rate estimate | BPM or `null` |
| `o2` | SpO₂ estimate | percent or `null`; emitted only after the bundled reference algorithm has enough valid optical samples |
| `t` | DHT22 **ambient** temperature | °C or `null`; never body temperature |
| `h` | DHT22 relative humidity | percent or `null` |
| `ax`, `ay`, `az` | MPU6050 acceleration | g or `null` |
| `gx`, `gy`, `gz` | MPU6050 gyroscope | degrees/second or `null` |
| `q` | Optical contact-quality heuristic | integer 0–100; not an accuracy claim |
| `f` | Finger/contact present | `1` or `0` |

The phone timestamps a frame on receipt because the Day 2 ESP32 has no trusted real-time clock.

## Notification framing

The JSON above is too large for the default BLE payload. The ESP32 therefore emits numbered ASCII fragments of at most 20 bytes:

```text
@<sequence>,<part>/<total>:<seven JSON bytes>
```

Example:

```text
@42,1/21:{"v":1,
@42,2/21:"u":183
...
```

- `sequence` is `0`–`999` and advances per JSON document.
- `part` starts at `1`; `total` is fixed for that sequence.
- Every fragment carries at most seven JSON bytes, making the largest possible framed notification no more than 20 bytes even on the default ATT MTU.
- The app accepts only ordered, matching fragments. A malformed, duplicate, missing, or out-of-sequence fragment discards that partial frame; the next 1 Hz frame can recover normally.
- The app parser also accepts an unframed complete JSON document for future larger-MTU firmware, but Day 2 firmware always frames packets explicitly.

## Android behavior

The app scans only for the service UUID above, connects, discovers services after each connection, enables characteristic notifications, and reconnects by resuming the filtered scan after a disconnect. Bluetooth scan/connect permissions are requested at runtime; no location is derived from BLE results.

## Diagnostics

Serial Monitor at **115200 baud** prints the reassembled JSON document once per second, followed by either `[BLE sent]` or `[BLE waiting for phone]`. This lets hardware debugging proceed without the Flutter app.
