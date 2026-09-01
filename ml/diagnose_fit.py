"""
Is the model over- or under-fitted?

The first training run hit its 200-epoch cap with validation loss still falling,
which is evidence of UNDER-training, not overfitting. This sweeps capacity and
lets each configuration train to genuine convergence, then reports the evidence
for both failure modes:

  OVERFITTING  -> validation loss turns upward while training loss keeps falling,
                  and the val/train gap widens.
  UNDERFITTING -> both losses are still falling when training stops, and adding
                  capacity keeps improving validation.

Selection is on VALIDATION AUC, never test. Reconstruction loss alone is the
wrong criterion for an anomaly detector: a high-capacity autoencoder eventually
reconstructs anomalies well too, which lowers loss while destroying detection.
Test is touched exactly once, at the end, for the single selected model.

Usage:
    python diagnose_fit.py
"""

import json
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

from train import AutoEncoder, recon_error, roc_auc, pr_metrics

HERE = Path(__file__).parent
DATA = HERE / "data" / "windows.npz"

SEED = 42
MAX_EPOCHS = 3000
PATIENCE = 150        # generous - we want genuine convergence, not an early exit
BATCH = 128
LR = 1e-3

# (hidden, latent) - from clearly too small to clearly too large
CONFIGS = [
    (8, 2),
    (16, 4),
    (32, 8),      # the shipped configuration
    (64, 16),
    (128, 32),
]


def train_one(Xtr, Xva_norm, n_in, hidden, latent, seed=SEED):
    torch.manual_seed(seed)
    model = AutoEncoder(n_in, hidden, latent)
    opt = torch.optim.Adam(model.parameters(), lr=LR)
    loss_fn = nn.MSELoss()

    best, best_state, bad, best_epoch = float("inf"), None, 0, 0
    history = []

    for epoch in range(1, MAX_EPOCHS + 1):
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

        model.eval()
        with torch.no_grad():
            val_loss = loss_fn(model(Xva_norm), Xva_norm).item()

        history.append((epoch, train_loss, val_loss))

        if val_loss < best - 1e-7:
            best, bad, best_epoch = val_loss, 0, epoch
            best_state = {k: v.clone() for k, v in model.state_dict().items()}
        else:
            bad += 1
            if bad >= PATIENCE:
                break

    model.load_state_dict(best_state)
    return model, history, best_epoch, best


def main():
    d = np.load(DATA, allow_pickle=True)
    X, y, split = d["X"], d["y"], d["split"]
    mean, std = d["mean"], d["std"]

    Xn = ((X - mean) / std).reshape(len(X), -1).astype(np.float32)
    n_in = Xn.shape[1]

    tr = (split == "train") & (y == 0)
    va_norm = (split == "val") & (y == 0)
    va_all = split == "val"
    te_all = split == "test"

    Xtr = torch.from_numpy(Xn[tr])
    Xva_norm = torch.from_numpy(Xn[va_norm])
    Xva = torch.from_numpy(Xn[va_all])
    Xte = torch.from_numpy(Xn[te_all])
    va_labels, te_labels = y[va_all], y[te_all]

    print(f"train(normal)={len(Xtr)}  val={len(Xva)}  test={len(Xte)}")
    print(f"max epochs {MAX_EPOCHS}, patience {PATIENCE}\n")

    header = f"{'hidden':>7} {'latent':>7} {'params':>8} {'epochs':>7} {'train':>9} {'val':>9} {'val/train':>10} {'val AUC':>9}"
    print(header)
    print("-" * len(header))

    results = []
    for hidden, latent in CONFIGS:
        model, hist, best_epoch, best_val = train_one(Xtr, Xva_norm, n_in, hidden, latent)
        n_params = sum(p.numel() for p in model.parameters())

        final_train = hist[best_epoch - 1][1]
        gap = best_val / final_train if final_train > 0 else float("nan")
        v_auc = roc_auc(recon_error(model, Xva), va_labels)

        print(f"{hidden:>7} {latent:>7} {n_params:>8,} {best_epoch:>7} "
              f"{final_train:>9.5f} {best_val:>9.5f} {gap:>10.2f} {v_auc:>9.3f}")

        results.append(dict(hidden=hidden, latent=latent, params=n_params, epochs=best_epoch,
                            train=final_train, val=best_val, gap=gap, val_auc=float(v_auc),
                            model=model, hist=hist))

    # --- fit diagnosis, from the evidence above ---
    print("\n=== diagnosis ===")
    for r in results:
        tail = r["hist"][-PATIENCE:] if len(r["hist"]) > PATIENCE else r["hist"]
        still_falling = tail[0][2] - tail[-1][2] > 1e-5
        hit_cap = r["epochs"] >= MAX_EPOCHS - PATIENCE
        verdict = []
        if r["gap"] > 1.5:
            verdict.append("val/train gap wide -> overfitting")
        if hit_cap and still_falling:
            verdict.append("hit epoch cap while improving -> undertrained")
        if not verdict:
            verdict.append("converged, gap healthy")
        print(f"  hidden={r['hidden']:<4} latent={r['latent']:<3} : {'; '.join(verdict)}")

    # --- select on VALIDATION AUC ---
    best = max(results, key=lambda r: r["val_auc"])
    print(f"\nselected on validation AUC: hidden={best['hidden']} latent={best['latent']} "
          f"({best['params']:,} params, val AUC {best['val_auc']:.3f})")

    # --- touch test exactly once ---
    te_auc = roc_auc(recon_error(best["model"], Xte), te_labels)
    print(f"test AUC for that model   : {te_auc:.3f}")

    shipped = next(r for r in results if (r["hidden"], r["latent"]) == (32, 8))
    print(f"shipped config (32/8)     : val AUC {shipped['val_auc']:.3f}, "
          f"converged at epoch {shipped['epochs']}")

    out = HERE / "artifacts" / "fit_diagnosis.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(
        [{k: v for k, v in r.items() if k not in ("model", "hist")} for r in results], indent=2))
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
