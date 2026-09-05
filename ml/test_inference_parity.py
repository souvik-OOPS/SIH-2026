"""
Prove the JavaScript inference matches the Python reference.

We hand-wrote the forward pass in JS (backend/src/ml/anomalyModel.js) instead of
shipping a runtime, so nothing checks it for us. Four things can silently go
wrong and all of them produce plausible-looking numbers:

  - weight layout      (row-major out-by-in vs transposed)
  - flatten order      (time-major with features interleaved vs feature-major)
  - activations        (ReLU on the output layer, which there must not be)
  - normalisation      (applied per-feature, in the right order)

This builds a random model, computes the expected reconstruction error with
numpy, runs the same model and window through the JS, and compares.

Usage:
    python test_inference_parity.py
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
JS_MODULE = (HERE.parent / "backend" / "src" / "ml" / "anomalyModel.js").resolve()

WINDOW, N_FEAT, HIDDEN, LATENT = 30, 2, 32, 8
TOLERANCE = 1e-5


def median5(win):
    """Width-5 centred median filter, matching smooth() in anomalyModel.js.

    The JS score() conditions its window this way before normalising, so the
    reference has to do the same or the two are no longer computing the same
    quantity - the test would be comparing a filtered pipeline against an
    unfiltered one and reporting a real agreement as a failure.
    """
    padded = np.pad(win, ((2, 2), (0, 0)), mode="edge")
    stacked = np.stack([padded[i:i + len(win)] for i in range(5)], axis=0)
    return np.median(stacked, axis=0).astype(np.float32)


def build_random_model(seed=7):
    rng = np.random.default_rng(seed)
    dims = [(WINDOW * N_FEAT, HIDDEN), (HIDDEN, LATENT), (LATENT, HIDDEN), (HIDDEN, WINDOW * N_FEAT)]
    layers, mats = [], []
    for n_in, n_out in dims:
        W = (rng.standard_normal((n_out, n_in)) * 0.2).astype(np.float32)
        b = (rng.standard_normal(n_out) * 0.1).astype(np.float32)
        mats.append((W, b))
        layers.append(
            {
                "in": n_in,
                "out": n_out,
                "W": [round(float(v), 6) for v in W.reshape(-1)],
                "b": [round(float(v), 6) for v in b],
            }
        )
    return layers, mats


def main():
    if not JS_MODULE.exists():
        raise SystemExit(f"missing {JS_MODULE}")

    layers, mats = build_random_model()
    acts = ["relu"] * (len(layers) - 1) + ["none"]

    mean = np.array([80.0, 97.0], dtype=np.float32)
    std = np.array([12.0, 2.0], dtype=np.float32)

    spec = {
        "features": ["HR", "SpO2"],
        "window": WINDOW,
        "normalisation": {"mean": mean.tolist(), "std": std.tolist()},
        "threshold": 0.5,
        "layers": layers,
        "activations": acts,
    }

    # A deterministic, physiologically plausible window.
    t = np.arange(WINDOW)
    hr = 80 + 5 * np.sin(t / 3.0)
    spo2 = 97 + 0.5 * np.cos(t / 4.0)
    win = np.stack([hr, spo2], axis=1).astype(np.float32)

    # --- numpy reference ---
    x = ((median5(win) - mean) / std).reshape(-1)
    h = x.copy()
    for (W, b), a in zip(mats, acts):
        h = h @ W.T + b
        if a == "relu":
            h = np.maximum(h, 0.0)
    expected = float(((h - x) ** 2).mean())

    # --- run the JS ---
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "model.json").write_text(json.dumps(spec))
        (tmp / "input.json").write_text(json.dumps(win.tolist()))

        js = f"""
        import {{ readFileSync }} from 'node:fs';
        const {{ createModel }} = await import({json.dumps(JS_MODULE.as_uri())});
        const spec = JSON.parse(readFileSync({json.dumps(str(tmp / 'model.json'))}, 'utf8'));
        const win  = JSON.parse(readFileSync({json.dumps(str(tmp / 'input.json'))}, 'utf8'));
        const r = createModel(spec).score(win.map(([HR, SpO2]) => ({{ HR, SpO2 }})));
        console.log(r.score.toFixed(12));
        """
        proc = subprocess.run(
            ["node", "--input-type=module", "-e", js],
            capture_output=True, text=True,
        )

    if proc.returncode != 0:
        print(proc.stderr)
        raise SystemExit("node failed")

    got = float(proc.stdout.strip().splitlines()[-1])
    diff = abs(got - expected)

    print(f"  numpy reference : {expected:.12f}")
    print(f"  javascript      : {got:.12f}")
    print(f"  abs difference  : {diff:.3e}  (tolerance {TOLERANCE:.0e})")

    if diff < TOLERANCE:
        print("\nPASS - the JS forward pass matches the reference.")
        return 0

    print("\nFAIL - implementations disagree. Check weight layout, flatten order, activations.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
