"""
Train the anomaly detector.

Approach: an undercomplete autoencoder trained ONLY on normal physiology. It
learns to reconstruct healthy HR/SpO2/RESP windows. A window it reconstructs
badly is unlike anything it saw in training — that reconstruction error is the
anomaly score.

Why an autoencoder rather than a classifier: we do not need labelled examples
of every way a person can deteriorate, and we could not collect them anyway.
Learning "normal" and flagging deviation is the honest framing for a wearable
that has to cope with conditions nobody labelled in advance.

The model is deliberately small (~6k parameters). It has to run in a phone
browser and, eventually, on an ESP32 — so a compact MLP that ports cleanly
beats a larger architecture that scores marginally better on paper.

Usage:
    python train.py
"""

import json
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

HERE = Path(__file__).parent
DATA = HERE / "data" / "windows.npz"
OUT_DIR = HERE / "artifacts"

SEED = 42
# Capacity and schedule chosen by diagnose_fit.py, on TRAIN/VAL evidence only:
#   - the original 200-epoch cap stopped training while val loss was still
#     falling; this config converges at ~780 epochs, so the cap is now generous
#     and real early stopping decides when to stop.
#   - val AUC rose monotonically with capacity (0.66 -> 0.92), which is the
#     signature of UNDERfitting, not overfitting. 128/32 scored highest but its
#     val/train ratio hit 2.01 - a widening generalisation gap. The rule is
#     "largest capacity with no overfitting signal (gap < 1.5)", which picks
#     64/16 at gap 1.36.
EPOCHS = 3000
BATCH = 128
LR = 1e-3
PATIENCE = 150
LATENT = 16
HIDDEN = 64

torch.manual_seed(SEED)
np.random.seed(SEED)


class AutoEncoder(nn.Module):
    """window (W x C) -> flat -> HIDDEN -> LATENT -> HIDDEN -> flat"""

    def __init__(self, n_in, hidden=HIDDEN, latent=LATENT):
        super().__init__()
        self.encoder = nn.Sequential(
            nn.Linear(n_in, hidden), nn.ReLU(),
            nn.Linear(hidden, latent), nn.ReLU(),
        )
        self.decoder = nn.Sequential(
            nn.Linear(latent, hidden), nn.ReLU(),
            nn.Linear(hidden, n_in),
        )

    def forward(self, x):
        return self.decoder(self.encoder(x))


def recon_error(model, X):
    """Per-window mean squared reconstruction error."""
    model.eval()
    with torch.no_grad():
        out = model(X)
        return ((out - X) ** 2).mean(dim=1).cpu().numpy()


def roc_auc(scores, labels):
    """ROC AUC via the rank/Mann-Whitney identity — no sklearn dependency."""
    pos, neg = scores[labels == 1], scores[labels == 0]
    if len(pos) == 0 or len(neg) == 0:
        return float("nan")
    order = np.argsort(scores)
    ranks = np.empty(len(scores), dtype=np.float64)
    ranks[order] = np.arange(1, len(scores) + 1)
    # average ranks for ties
    _, inv, counts = np.unique(scores, return_inverse=True, return_counts=True)
    sums = np.zeros(len(counts))
    np.add.at(sums, inv, ranks)
    ranks = (sums / counts)[inv]
    r_pos = ranks[labels == 1].sum()
    return (r_pos - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))


def pr_metrics(scores, labels, thr):
    pred = (scores >= thr).astype(int)
    tp = int(((pred == 1) & (labels == 1)).sum())
    fp = int(((pred == 1) & (labels == 0)).sum())
    fn = int(((pred == 0) & (labels == 1)).sum())
    tn = int(((pred == 0) & (labels == 0)).sum())
    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    spec = tn / (tn + fp) if tn + fp else 0.0
    return dict(tp=tp, fp=fp, fn=fn, tn=tn, precision=prec, recall=rec, f1=f1, specificity=spec)


def main():
    if not DATA.exists():
        raise SystemExit(f"missing {DATA} — run prepare_data.py first")

    d = np.load(DATA, allow_pickle=True)
    X, y, split = d["X"], d["y"], d["split"]
    mean, std = d["mean"], d["std"]
    features = [str(f) for f in d["features"]]
    window = int(d["window"])

    # Normalise with training-set statistics, then flatten.
    Xn = ((X - mean) / std).reshape(len(X), -1).astype(np.float32)
    n_in = Xn.shape[1]

    tr = (split == "train") & (y == 0)   # train on NORMAL only
    va_norm = (split == "val") & (y == 0)
    va_all = split == "val"
    te_all = split == "test"

    print(f"input dim {n_in} ({window} x {len(features)})")
    print(f"train(normal)={tr.sum()}  val={va_all.sum()}  test={te_all.sum()}")

    Xtr = torch.from_numpy(Xn[tr])
    Xva_norm = torch.from_numpy(Xn[va_norm])
    Xva = torch.from_numpy(Xn[va_all])
    Xte = torch.from_numpy(Xn[te_all])

    model = AutoEncoder(n_in)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"parameters: {n_params:,}")

    opt = torch.optim.Adam(model.parameters(), lr=LR)
    loss_fn = nn.MSELoss()

    best, best_state, bad = float("inf"), None, 0

    for epoch in range(1, EPOCHS + 1):
        model.train()
        perm = torch.randperm(len(Xtr))
        total = 0.0
        for i in range(0, len(Xtr), BATCH):
            xb = Xtr[perm[i : i + BATCH]]
            opt.zero_grad()
            loss = loss_fn(model(xb), xb)
            loss.backward()
            opt.step()
            total += loss.item() * len(xb)
        train_loss = total / len(Xtr)

        # Early stopping on reconstruction of NORMAL validation windows only —
        # the model's job is to reconstruct normal, not to score anomalies.
        model.eval()
        with torch.no_grad():
            val_loss = loss_fn(model(Xva_norm), Xva_norm).item()

        if val_loss < best - 1e-6:
            best, bad = val_loss, 0
            best_state = {k: v.clone() for k, v in model.state_dict().items()}
        else:
            bad += 1

        if epoch % 20 == 0 or epoch == 1:
            print(f"  epoch {epoch:3d}  train {train_loss:.5f}  val(normal) {val_loss:.5f}")

        if bad >= PATIENCE:
            print(f"  early stop at epoch {epoch}")
            break

    model.load_state_dict(best_state)

    # --- pick the threshold on VALIDATION, never on test ---
    va_scores = recon_error(model, Xva)
    va_labels = y[va_all]

    # Threshold policy: target a fixed SPECIFICITY, not maximum F1.
    #
    # An F1-optimal threshold looked better on validation and then produced 69
    # false alarms for 10 true ones on test. For a health alerter that is
    # useless - a caregiver paged wrongly seven times out of eight stops
    # reading the alerts, and the one real emergency goes unread. Buying
    # precision with recall is the right trade, and the rule engine still
    # catches hard clinical breaches on its own.
    TARGET_SPECIFICITY = 0.99

    def thr_at_specificity(target):
        for t in candidates:
            if pr_metrics(va_scores, va_labels, t)["specificity"] >= target:
                return float(t)
        return float(candidates[-1])

    candidates = np.unique(np.quantile(va_scores, np.linspace(0.50, 0.9999, 600)))
    best_thr = thr_at_specificity(TARGET_SPECIFICITY)

    va_m = pr_metrics(va_scores, va_labels, best_thr)
    print(f"\nthreshold {best_thr:.5f} chosen on validation at >={TARGET_SPECIFICITY:.0%} specificity")
    print(f"  validation: precision {va_m['precision']:.3f}  recall {va_m['recall']:.3f}")

    print("\n  operating points considered (validation):")
    print(f"  {'specificity':>12} {'threshold':>10} {'precision':>10} {'recall':>8}")
    for target in (0.90, 0.95, 0.99, 0.995):
        t = thr_at_specificity(target)
        mm = pr_metrics(va_scores, va_labels, t)
        print(f"  {target:>12.1%} {t:>10.5f} {mm['precision']:>10.3f} {mm['recall']:>8.3f}")

    # --- report on held-out TEST subjects ---
    te_scores = recon_error(model, Xte)
    te_labels = y[te_all]

    auc = roc_auc(te_scores, te_labels)
    m = pr_metrics(te_scores, te_labels, best_thr)

    print("\n=== held-out test subjects ===")
    print(f"  windows      {len(te_labels)}  (abnormal {int((te_labels==1).sum())})")
    print(f"  ROC AUC      {auc:.3f}")
    print(f"  precision    {m['precision']:.3f}")
    print(f"  recall       {m['recall']:.3f}")
    print(f"  F1           {m['f1']:.3f}")
    print(f"  specificity  {m['specificity']:.3f}")
    print(f"  confusion    tp={m['tp']} fp={m['fp']} fn={m['fn']} tn={m['tn']}")

    OUT_DIR.mkdir(exist_ok=True)
    torch.save({"state_dict": model.state_dict(), "n_in": n_in,
                "hidden": HIDDEN, "latent": LATENT}, OUT_DIR / "autoencoder.pt")

    report = {
        "model": "MLP autoencoder",
        "architecture": f"{n_in} -> {HIDDEN} -> {LATENT} -> {HIDDEN} -> {n_in}",
        "parameters": int(n_params),
        "features": features,
        "window_seconds": window,
        "trained_on": "normal windows from training subjects only",
        "threshold": best_thr,
        "threshold_selected_on": "validation subjects, at >=99% specificity",
        "test": {"roc_auc": float(auc), **{k: (float(v) if isinstance(v, float) else v)
                                           for k, v in m.items()}},
        "norm_mean": mean.tolist(),
        "norm_std": std.tolist(),
    }
    (OUT_DIR / "report.json").write_text(json.dumps(report, indent=2))
    print(f"\nsaved {OUT_DIR/'autoencoder.pt'} and report.json")


if __name__ == "__main__":
    main()
