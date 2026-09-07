# Flutter-first review — 7 September 2026

## Flutter versus the PWA

Flutter already had BLE, replay, a live HR chart, signal gating, personal baseline
rules, an exported anomaly autoencoder, and manual SMS. Its biggest product gaps
were saved history, notification delivery, background lifecycle, and fall check-in
interaction. The earlier Qwen NPU integration always reported unavailable.

A single percentage would be misleading: the PWA relies on backend services
while Flutter runs core monitoring on the phone. This matrix compares features
verified in the repository, not a browser visual/usability benchmark.

| Capability | PWA/backend | Flutter after this change |
|---|---|---|
| Live dashboard | Present | Present; direct BLE and signal-aware HR chart |
| Explainable risk / baseline | Backend | On device |
| Learned anomaly detection | Exported autoencoder | Same exported weights; parity tests |
| History | Multiple charts and selectable ranges | Added interactive HR/O2/air/humidity charts, 15m–7d ranges, statistics, source filters; heat-index trend still absent |
| Alert history/review | Present | Added local history, review action and Android notifications |
| Operation off-screen | Browser/platform dependent | Added Android connected-device foreground service |
| Fall check-in | Overlay/backend workflow | Added I'm OK action; fixed timeout without packets and rearming |
| Offline assistant | No comparable native model runtime | Improved EN/HI guide, state policy, optional Qwen CPU |
| Privacy | Baseline reset, data summary/deletion | Added journal deletion/storage explanation; baseline reset UI still missing |
| Emergency responder packet | Present on backend | Added local preview and Android sharing, with freshness/trust labels and recent evidence; no location collection |
| SACHET disaster context | Present with source/freshness handling | Still missing |
| Weather/AQI context | Backend environmental context | Still missing; sensor temperature is ambient air, not AQI/body temperature |
| Contacts/SMS | Backend integration | Native contacts/manual SMS; notification alerts do not automatically send SMS |

Flutter now has the stronger foundation for the requested offline wearable use
case. The largest remaining parity work is disaster/environmental context,
baseline-reset controls, and the heat-index history series.

## Implementation

- The Android Application owns the Flutter engine across activity removal. A
  user-started foreground service keeps a persistent notification and partial CPU
  wake lock during monitoring. Stop disconnects the wearable.
- Sustained unusual HR/O2, risk, falls, unanswered check-ins, poor contact, and
  interrupted readings generate local alerts. Signal gating and cooldowns reduce
  false/repeated physiological notifications.
- SQLite stores seven days of sampled readings and up to 500 alerts. Replay is
  labelled; demo notifications require a separate toggle. Activity/Settings expose
  review and delete controls. Android cloud backup is disabled.
- Activity now offers 15m/1h/6h/24h/7d charts with separate Wearable/Demo sources.
  SQLite aggregation bounds chart data to about 180 intervals; statistics remain
  sample-weighted over the full selected period. Mixed-validity intervals and
  recording gaps over 20 seconds break the line. Individual interval inspection
  shows the average/range or the gap. The raw list is separately capped at 720.
- Emergency summaries capture an immutable local snapshot, including freshness,
  trust, risk, recent ten-minute statistics and alerts. Stale pulse values are
  withheld; historical values and DEMO data are labelled. Sharing opens Android's
  chooser and never claims delivery. The Live dashboard now also hides current
  values after monitoring stops or readings become stale/unreliable.
- Urgent/current-state assistant questions bypass generation. A final live-state
  check also supersedes generated text if risk rises while generating. Stale or
  unreliable physiological numbers are suppressed. Guide answers show sources;
  conversation context is bounded and English/Hindi guide coverage is balanced.
- Guide retrieval ranks the full small corpus rather than taking the first
  database OR-match. Actual GGUF CPU inference replaces the unavailable NPU stub.
  The model imports into private storage; the guide works without it. Native
  kernels remain optimized in debug APKs. Diagnostics measures real timings.
- Inverted post-fall movement evidence is fixed. A fall check-in can expire
  without another BLE packet; escalation remains latched through stale-data
  reassessment until the wearer resolves it. Ordinary movement rearms detection.

## SIH positioning and ML priorities

The strongest demonstrable story is **a wearable companion that continues
locally during a network outage and explains unusual readings and unreliable
sensors**. Demonstrate phone lock/unlock, loss of contact, recovery, a fall
check-in, clearly labelled replay alerts, and the same incident in local history.
These are measurable behaviours; another chatbot alone does not establish novelty
or guarantee SIH selection.

Keep the existing small autoencoder as a second opinion. Its anomaly ratio is
not a probability and must not be mapped arbitrarily into risk points. The next
valuable model is a signal-quality classifier trained on labelled contact/motion
artefacts from this sensor enclosure. A compact tree model or 1D CNN is a candidate
once the raw-signal dataset exists. Validate on held-out wearers and across skin
tones, activity, and sensor placement.

For falls, collect impact/posture/stillness sequences and compare the rules with
a compact temporal model. Report false alerts per wearer-hour and missed events,
not accuracy alone. Ambient heat plus HR supports exposure context, not a heatstroke
diagnosis. Evaluate the LLM separately for English/Hindi correctness, preservation
of urgent state, latency, memory, and battery cost. No new trained model or clinical
validation is claimed in this change.

## Validation and limits

Android ARM64 is the implemented target; iOS background BLE is not implemented. Force-stop,
reboot, disabled Bluetooth, revoked permissions, and OEM battery restrictions can
stop monitoring. The wake lock costs battery; overnight battery/Doze testing remains
necessary before field use. Notification posting does not guarantee sound, user
acknowledgement, or delivery to a carer.

The live test wearable had unreliable/no-finger optical data. Environment readings
and contact alerts verify the live pipeline; abnormal HR/O2 is exercised with
fixtures/tests without inventing valid measurements. The debug APK is for testing.
The repository's release configuration still uses debug signing credentials.

### Verified in this workspace

- `flutter test`: **128 passed**. This includes sustained high/low HR and oxygen
  thresholds, cooldown/escalation, bad-signal and disconnected-data suppression,
  fall timeout without packets/rearming, assistant urgent-state enforcement,
  real guide retrieval/Hindi corpus checks, existing ML parity regressions,
  history filtering/aggregation/outage handling, emergency-summary safety, source/
  range/timer refresh interactions, and sharing exactly the displayed snapshot.
- `flutter analyze --no-fatal-infos`: passed with no errors or warnings; eight
  existing `prefer_initializing_formals` style notices remain.
- Debug APK built successfully with the native CPU runtime. The model remains
  separate from the APK. The updated app was installed on the connected vivo
  I2202 (SM8250) Android phone.
- On that phone, Activity switched from Wearable/1h to Demo/24h and showed 103
  saved demo samples with separately counted usable pulse samples. Tapping a
  plotted interval displayed its timestamp, average and range. Wearable pulse
  history stayed empty when contact was unreliable, while ambient readings
  remained available. Source/range and periodic refresh bugs found during the
  device review are fixed and covered by widget regression tests.
- Emergency preview and snapshot refresh worked with live BLE data. Tapping
  Share opened Android's `ChooserActivity`; it was cancelled without choosing a
  recipient or sending data. The fresh snapshot withheld unreliable HR/O2.
  No Flutter/Android runtime errors appeared in the updated process during these
  checks. Live BLE reconnected after installation and monitoring remained active.
- Actual wearable BLE connected. Android reported a foreground service of type
  `connectedDevice` with the persistent monitoring notification. During a short
  Home/screen-lock check, the journal grew from 74 to 78 samples across roughly
  41 seconds, with varying live ambient readings and unusable pulse values saved
  as gaps. The service remained active. This is not an overnight reliability test.
- Android posted the live **Check sensor contact** notification. Replay with demo
  notifications enabled posted **Possible fall** and, about 30 seconds later,
  **Fall check-in unanswered**. Both had DEMO labels and were present in Activity.
- Tapping the persistent notification's **Stop monitoring** action left no active
  monitoring service; Settings reflected monitoring off. No SMS was sent.
- Actual Qwen generation for “Why is humidity important” completed with **43
  tokens in 13,518 ms** while live monitoring continued. Diagnostics measured
  initialization **1,018 ms**, first token **10,824 ms**, and throughput **3.2
  tokens/s including prompt processing**. App-process peak RSS was about **1,289
  MiB**; this is the whole app's process high-water mark, not model-only memory.
  These are one-device, one-prompt measurements, not general performance claims.
- The first unoptimized native debug build timed out and correctly used the guide.
  Optimizing the tensor kernels fixed the observed timeout on this phone.

Not yet physically verified: an overnight run/Doze, other Android manufacturers,
reboot/force-stop recovery on multiple OS versions, valid abnormal HR/O2 from a
real wearer, and model import through the document picker (the tested model was
copied into private debug-app storage). The import UI and native path compile;
fresh-install guide fallback is supported. No browser visual comparison was run.

## References

- [Android BLE background guidance](https://developer.android.com/develop/connectivity/bluetooth/ble/background).
- [Android Sharesheet guidance](https://developer.android.com/develop/ui/compose/sharing/send).
- [llama.cpp Android build guidance](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md); pinned revision in `tool/llama_revision.txt`.
- [Official Qwen3-0.6B GGUF card](https://huggingface.co/Qwen/Qwen3-0.6B-GGUF).
- [FDA pulse oximeter information](https://www.fda.gov/medical-devices/products-and-medical-procedures/pulse-oximeters): readings are estimates; symptoms and measurement limitations matter.
- [NIOSH heat illness guidance](https://www.cdc.gov/niosh/heat-stress/about/illnesses.html).
