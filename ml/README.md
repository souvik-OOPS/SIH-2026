# Anomaly detection model

On-device anomaly detection for the Personal Health Companion. Trained on **real patient vitals**, not on
our own simulator.

## Why an autoencoder, not a classifier

We cannot collect labelled examples of every way a person can deteriorate, and neither can anyone else. So
the model learns what *normal* physiology looks like and flags what it cannot reproduce. That is the honest
framing for a wearable that has to cope with conditions nobody labelled in advance.

It answers **"this does not look like your normal"** — never *"you have condition X."* It carries no
diagnostic labels and cannot name a condition. Say it that way to judges; the overclaim is what gets picked
apart.

## Dataset

**BIDMC PPG and Respiration Dataset v1.0.0** — [PhysioNet](https://physionet.org/content/bidmc/1.0.0/),
open access, no credentialing required.

> Pimentel et al., "Toward a Robust Estimation of Respiratory Rate from Pulse Oximeters,"
> *IEEE Transactions on Biomedical Engineering*, 2017.

53 recordings, 8 minutes each, from adult ICU patients at Beth Israel Deaconess Medical Center. We use the
1 Hz numerics — real heart rate and blood oxygen from real patients, which is exactly what the wearable
reports.

**Verify the licence terms before the finale.** PhysioNet open-access datasets carry their own licence and
required citation; both need to be on your references slide.

## Two decisions that make the numbers mean something

**1. The split is by subject, and stratified.** Consecutive windows from one patient are nearly identical, so
a random split puts near-duplicates in both train and test and every metric inflates. Splits here are by
recording ID.

They are also stratified by whether a subject has any abnormal window, and that mattered: only **9 of 53
recordings** contain one, and a plain random subject split left validation with **zero** positives — nothing
to choose a threshold on, and 8 positives in test. Stratifying keeps the subject-wise guarantee (no recording
in two splits) while giving every split some abnormal physiology.

**2. The model only ever sees normal windows in training.** Abnormal windows are held out entirely and used
only for evaluation. The threshold is chosen on the **validation** subjects and then applied unchanged to
test — choosing it on test would be reporting a number you tuned.

Normalisation statistics are computed from training-normal windows only, so no test distribution leaks in.

## Feature parity

The model takes **HR and SpO₂ only** — the two vitals the ESP32 actually produces.

BIDMC also carries respiration rate, and including it would improve reconstruction. It is deliberately left
out: our hardware has no respiration sensor, so a model that needs RESP at inference is untrainable-to-
deployable. Training and deployment must see the same features.

## Pipeline

```bash
cd ml

# 1. download the dataset (~218 MB) into data/bidmc.zip
curl -L -o data/bidmc.zip \
  "https://physionet.org/static/published-projects/bidmc/bidmc-ppg-and-respiration-dataset-1.0.0.zip"

# 2. windows + subject-wise split  ->  data/windows.npz
python prepare_data.py

# 3. train + evaluate on held-out subjects  ->  artifacts/autoencoder.pt, report.json
python train.py

# 4. export to plain JSON  ->  ../backend/src/ml/model.json
python export_weights.py
```

Requires `numpy` and `torch` (CPU is fine — the model is tiny). No TensorFlow, no ONNX.

## Why JSON weights instead of ONNX

The model is ~4k parameters: four `Linear` layers with ReLU. Hand-rolled inference is ~25 lines of
dependency-free JavaScript in [`backend/src/ml/anomalyModel.js`](../backend/src/ml/anomalyModel.js).

ONNX Runtime Web would cost a ~2 MB WASM download in a PWA whose whole selling point is working offline on a
bad connection. The JSON also ports straight to a C array for the ESP32, which an ONNX graph would not.
`export_weights.py` verifies the JSON reproduces the PyTorch output before writing it.

## Reporting the results

`artifacts/report.json` holds the metrics. Put the **held-out test** numbers on the slide, and say the split
was subject-wise — evaluators in this category will ask, and volunteering it reads as competence.

Report ROC AUC alongside precision/recall rather than accuracy alone: normal windows heavily outnumber
abnormal ones, so a model that predicts "normal" every time already scores high accuracy while being useless.

## Is it over- or under-fitted?

It was **under**-fitted, on both axes. `diagnose_fit.py` swept capacity with real early stopping
(`artifacts/fit_diagnosis.json`):

| hidden / latent | params | epochs to converge | val/train gap | val AUC |
|---|---|---|---|---|
| 8 / 2 | 1,070 | 692 | 1.25 | 0.663 |
| 16 / 4 | 2,144 | 506 | 1.31 | 0.693 |
| 32 / 8 *(first attempt)* | 4,484 | 556 | 1.26 | 0.793 |
| **64 / 16 (shipped)** | **9,932** | **778** | **1.36** | **0.871** |
| 128 / 32 | 23,900 | 1042 | 2.01 | 0.923 |

Two things were wrong with the first run:

1. **The epoch cap stopped it early.** It ran 200 epochs; the same config needs ~556 to converge. Validation
   loss was still falling when training stopped — the signature of undertraining, not overfitting.
2. **Capacity was too low.** Validation AUC rises monotonically with size, which only happens when the model
   is capacity-limited.

Selection rule, fixed before looking at test: **the largest capacity showing no overfitting signal**
(val/train gap < 1.5). That picks 64/16 — 128/32 scores higher on validation but its gap of 2.01 is a
widening generalisation gap, so it is rejected despite the better number.

Overfitting is *not* a concern at the shipped size: the val/train ratio is 1.36 and validation loss falls
monotonically to early stopping.

### Validation and test disagree, and the reason matters

Raising capacity lifted val AUC 0.793 -> 0.871 but left test AUC flat (0.817 -> 0.807). With **28 abnormal
windows from 3 subjects**, those are statistically indistinguishable. The bigger gap is the threshold:
**val precision 0.81 vs test precision 0.13** at the same cut.

That is inter-subject variation, not overfitting. One test subject (26) has a median reconstruction error of
0.0283 against a 0.0269 threshold while having *zero* clinically abnormal windows — unusual physiology that
is nonetheless healthy. That single patient produces most of the false positives.

**A fix that did not work, recorded so nobody retries it:** scoring each window against its own subject's
median/MAD instead of a global threshold. It sounds right and it is what "learns your normal" implies, but it
cut validation AUC to 0.658 — because three validation subjects are 100% abnormal, and normalising against
their own median makes their anomaly the baseline. Per-subject normalisation needs a known-healthy enrolment
period; it cannot be derived from the recording itself.

## Measured results (held-out subjects)

| | |
|---|---|
| Architecture | `60 -> 64 -> 16 -> 64 -> 60` MLP autoencoder |
| Parameters | **9,932** (98 KB as JSON) |
| Inputs | HR + SpO2, 30-second window at 1 Hz |
| **ROC AUC** | **0.807** |
| Specificity | 0.944 |
| Precision | 0.130 |
| Recall | 0.321 |
| Confusion | tp=9 fp=60 fn=19 tn=1004 |

**Read these honestly.** AUC 0.82 says the score carries real signal — it ranks abnormal windows above
normal ones far better than chance. Precision and recall at the operating point are modest, and the reason
is visible in the data: our "abnormal" label fires on *any* breach of a clinical bound, including windows
sitting at SpO2 91 against a threshold of 92. Those are genuinely borderline and the model is right not to
find them dramatic.

The threshold targets **99% specificity**, not best F1. An F1-optimal threshold scored better on paper and
produced 69 false alarms for 10 true ones — a caregiver paged wrongly seven times in eight stops reading
alerts, and the real emergency goes unread. Precision bought with recall is the correct trade here.

Evaluation rests on **3 abnormal-carrying subjects** (28 abnormal windows), because only 9 of 53 recordings
contain any. Report that alongside the numbers; a small positive set makes every metric noisy, and saying so
first is stronger than being asked.

## The model does not carry the detection load

The rules do. This is deliberate and worth stating plainly if asked:

- A **sustained flat extreme** — SpO2 pinned at 84 for 30 seconds — reconstructs *well* and scores LOW. An
  autoencoder finds constant signals easy regardless of their value. That is a real blind spot.
- It does not matter, because that exact case is what the threshold rules catch instantly (SpO2 < 88 fires a
  critical alert with no sustain window).

So the two are complementary rather than redundant: **rules catch hard clinical breaches, the model catches
pattern deviations the thresholds miss.** The model never suppresses a rule, and `ML_ALERT_RATIO` in
`anomalyDetection.js` requires a large, sustained excursion before it raises anything on its own.

## Honest limitations

- **ICU patients are not outdoor workers.** BIDMC is resting hospital data, so it contains almost no exercise
  physiology. A raised heart rate from walking looks abnormal to a model trained on bed-rest. This is why the
  model output is one input to the alert decision, not the whole of it — the heat-index and strain rules still
  carry the exertion context.
- **8-minute recordings** limit how much long-horizon drift the model can learn.
- The abnormal labels come from clinical thresholds on the same signals the model sees, so the evaluation
  measures "can it find the deviations we defined," not "can it predict a clinical outcome."
- Not a medical device. Prototype only.
