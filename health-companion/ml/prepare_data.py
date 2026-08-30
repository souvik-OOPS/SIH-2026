"""
Turn the BIDMC dataset into training windows.

Dataset: BIDMC PPG and Respiration Dataset (PhysioNet, open access)
  Pimentel et al., "Toward a Robust Estimation of Respiratory Rate from Pulse
  Oximeters", IEEE Trans. Biomed. Eng., 2017.
  53 recordings, 8 minutes each, from adult ICU patients at Beth Israel
  Deaconess Medical Center. We use the 1 Hz *numerics*: HR, SpO2, RESP.

Why this dataset: it carries real heart rate and blood oxygen from real
patients, which are exactly the two vitals the wearable reports. Training on
our own simulator would be circular — the model would learn the simulator.

Two methodology choices that decide whether the numbers mean anything:

  1. SPLIT BY SUBJECT, never randomly.
     Consecutive windows from one patient are nearly identical. A random split
     puts near-duplicates in both train and test, and accuracy goes up without
     the model learning anything. Every split here is by recording ID.

  2. TRAIN ONLY ON NORMAL WINDOWS.
     The autoencoder learns to reconstruct healthy physiology. Anything it
     reconstructs badly is, by construction, unlike what it was trained on.
     Abnormal windows are held out entirely and used only for evaluation.

Usage:
    python prepare_data.py            # reads data/bidmc.zip, writes data/windows.npz
"""

import csv
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
# The 1 Hz numerics are all we need. The full dataset zip is 218 MB, almost
# entirely raw waveform data we never touch, so we fetch the 53 numerics CSVs
# directly instead (~476 KB total). See README.md for the download command.
CSV_DIR = HERE / "data" / "numerics"
OUT_PATH = HERE / "data" / "windows.npz"

# 30 samples at 1 Hz = a 30-second window, which is also the sustain window the
# rule engine uses. Keeping them equal makes the two comparable.
WINDOW = 30
STRIDE = 5  # overlapping windows, for more training data

# ONLY features the wearable actually produces. BIDMC also carries RESP
# (respiration rate), and including it would improve reconstruction — but the
# ESP32 has no respiration sensor, so a model that needs RESP at inference time
# is untrainable-to-deployable. Feature parity between training and deployment
# is not negotiable.
FEATURES = ["HR", "SpO2"]

# Physiological plausibility. Values outside these are sensor dropout, not
# physiology, and are dropped rather than treated as extreme readings.
VALID = {"HR": (20, 250), "SpO2": (50, 100)}

# What counts as clinically abnormal. These mirror the thresholds in
# backend/src/services/anomalyDetection.js so the model is evaluated against
# the same definition the product uses.
ABNORMAL = {
    "HR": lambda v: (v > 120) | (v < 50),
    "SpO2": lambda v: v < 92,
}


def find_numerics():
    """The per-recording numerics CSVs on disk."""
    return sorted(CSV_DIR.glob("*_Numerics.csv"))


def subject_id(path):
    """bidmc_07_Numerics.csv -> '07'"""
    return Path(path).stem.split("_")[1]


def read_numerics(path):
    """
    Return {column: np.array} for one recording.

    Column names carry leading spaces and unit suffixes (' HR', ' SpO2'), so
    match loosely rather than by exact string.
    """
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        rows = list(csv.reader(fh))

    if not rows:
        return {}

    header = [h.strip() for h in rows[0]]
    cols = defaultdict(list)

    wanted = {}
    for i, h in enumerate(header):
        key = h.split("[")[0].strip().upper()
        for feat in FEATURES:
            if key == feat.upper():
                wanted[i] = feat

    for row in rows[1:]:
        for i, feat in wanted.items():
            if i >= len(row):
                cols[feat].append(np.nan)
                continue
            raw = row[i].strip()
            try:
                cols[feat].append(float(raw))
            except ValueError:
                cols[feat].append(np.nan)

    return {k: np.asarray(v, dtype=np.float32) for k, v in cols.items()}


def clean(series):
    """NaN out implausible values, then fill short gaps by interpolation."""
    out = {}
    for feat, arr in series.items():
        lo, hi = VALID[feat]
        arr = arr.copy()
        arr[(arr < lo) | (arr > hi)] = np.nan

        idx = np.arange(len(arr))
        good = ~np.isnan(arr)
        if good.sum() < 2:
            return None  # recording unusable for this feature
        arr = np.interp(idx, idx[good], arr[good]).astype(np.float32)
        out[feat] = arr
    return out


def window_recording(series, sid):
    """Slice one recording into overlapping windows, labelled normal/abnormal."""
    n = min(len(series[f]) for f in FEATURES)
    if n < WINDOW:
        return [], [], []

    stacked = np.stack([series[f][:n] for f in FEATURES], axis=1)  # (n, 3)

    windows, labels, sids = [], [], []
    for start in range(0, n - WINDOW + 1, STRIDE):
        w = stacked[start : start + WINDOW]

        # A window is abnormal if ANY sample in it breaches a clinical bound.
        flag = False
        for feat, test in ABNORMAL.items():
            j = FEATURES.index(feat)
            if bool(np.any(test(w[:, j]))):
                flag = True
                break

        windows.append(w)
        labels.append(1 if flag else 0)
        sids.append(sid)

    return windows, labels, sids


def main():
    if not CSV_DIR.exists():
        raise SystemExit(f"missing {CSV_DIR} — download the numerics first (see README.md)")

    files = find_numerics()
    if not files:
        raise SystemExit(f"no *_Numerics.csv in {CSV_DIR}")

    print(f"found {len(files)} recordings")

    all_w, all_y, all_s = [], [], []
    skipped = []

    for name in files:
        sid = subject_id(name)
        series = read_numerics(name)

        missing = [f for f in FEATURES if f not in series or len(series[f]) == 0]
        if missing:
            skipped.append((sid, f"missing {missing}"))
            continue

        series = clean(series)
        if series is None:
            skipped.append((sid, "too few valid samples"))
            continue

        w, y, s = window_recording(series, sid)
        if not w:
            skipped.append((sid, "too short"))
            continue

        all_w.extend(w)
        all_y.extend(y)
        all_s.extend(s)

    X = np.asarray(all_w, dtype=np.float32)
    y = np.asarray(all_y, dtype=np.int64)
    subjects = np.asarray(all_s)

    print(f"windows: {len(X)}  normal: {(y == 0).sum()}  abnormal: {(y == 1).sum()}")
    if skipped:
        print(f"skipped {len(skipped)} recordings: {skipped[:5]}{' ...' if len(skipped) > 5 else ''}")

    uniq = sorted(set(subjects.tolist()))
    print(f"subjects usable: {len(uniq)}")

    # --- subject-wise split, STRATIFIED by whether a subject has any abnormal
    #     windows.
    #
    #     Only 9 of the 53 recordings contain a clinically abnormal window, and
    #     they are not spread evenly. A plain random subject split put all but
    #     eight abnormal windows into train, leaving validation with ZERO
    #     positives — no way to choose a threshold, and nothing meaningful to
    #     measure on test. Stratifying keeps the subject-wise guarantee (no
    #     recording appears in two splits) while ensuring every split sees some
    #     abnormal physiology.
    rng = np.random.default_rng(42)

    has_abnormal = {sid: bool(y[subjects == sid].any()) for sid in uniq}
    pos = sorted([s for s in uniq if has_abnormal[s]])
    neg = sorted([s for s in uniq if not has_abnormal[s]])

    def split_group(group, fracs=(0.34, 0.33, 0.33)):
        g = [group[i] for i in rng.permutation(len(group))]
        n1 = max(1, int(round(len(g) * fracs[0]))) if g else 0
        n2 = max(1, int(round(len(g) * fracs[1]))) if len(g) > 1 else 0
        return g[:n1], g[n1 : n1 + n2], g[n1 + n2 :]

    # Positive subjects are the scarce resource - spread them evenly.
    p_tr, p_va, p_te = split_group(pos)
    # Negative subjects mostly feed training, which only ever sees normal data.
    n_tr_g, n_va_g, n_te_g = split_group(neg, fracs=(0.6, 0.2, 0.2))

    train_s = set(p_tr) | set(n_tr_g)
    val_s = set(p_va) | set(n_va_g)
    test_s = set(p_te) | set(n_te_g)

    print(f"abnormal-carrying subjects: {len(pos)} of {len(uniq)} "
          f"-> train {len(p_tr)}, val {len(p_va)}, test {len(p_te)}")

    assert not (train_s & val_s) and not (train_s & test_s) and not (val_s & test_s)

    split = np.array(
        ["train" if s in train_s else "val" if s in val_s else "test" for s in subjects]
    )

    for part in ("train", "val", "test"):
        m = split == part
        print(
            f"  {part:5s} subjects={len({s for s, k in zip(subjects, split) if k == part}):2d} "
            f"windows={m.sum():5d} abnormal={(y[m] == 1).sum():4d}"
        )

    # Normalisation statistics come from TRAINING NORMAL windows only.
    # Computing them over everything would leak test distribution into the model.
    fit_mask = (split == "train") & (y == 0)
    flat = X[fit_mask].reshape(-1, len(FEATURES))
    mean = flat.mean(axis=0)
    std = flat.std(axis=0)
    std[std < 1e-6] = 1.0

    print(f"norm mean={np.round(mean, 2).tolist()} std={np.round(std, 2).tolist()}")

    np.savez_compressed(
        OUT_PATH,
        X=X, y=y, subjects=subjects, split=split,
        mean=mean.astype(np.float32), std=std.astype(np.float32),
        features=np.array(FEATURES), window=WINDOW,
    )

    meta = {
        "dataset": "BIDMC PPG and Respiration Dataset v1.0.0 (PhysioNet)",
        "citation": "Pimentel et al., IEEE TBME 2017",
        "features": FEATURES,
        "window_seconds": WINDOW,
        "stride": STRIDE,
        "recordings_used": len(uniq),
        "windows_total": int(len(X)),
        "abnormal_total": int((y == 1).sum()),
        "split": "subject-wise 60/20/20, seed 42",
        "norm_mean": mean.tolist(),
        "norm_std": std.tolist(),
    }
    (HERE / "data" / "dataset_meta.json").write_text(json.dumps(meta, indent=2))

    print(f"\nwrote {OUT_PATH}")


if __name__ == "__main__":
    main()
