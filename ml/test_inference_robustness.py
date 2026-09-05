"""
Extended robustness and parity testing for ML inference across edge conditions.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
JS_MODULE = (HERE.parent / "backend" / "src" / "ml" / "anomalyModel.js").resolve()
TOLERANCE = 1e-5


def run_js_score(spec, window_samples):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "model.json").write_text(json.dumps(spec))
        (tmp / "input.json").write_text(json.dumps(window_samples))

        js = f"""
        import {{ readFileSync }} from 'node:fs';
        const {{ createModel }} = await import({json.dumps(JS_MODULE.as_uri())});
        const spec = JSON.parse(readFileSync({json.dumps(str(tmp / 'model.json'))}, 'utf8'));
        const win  = JSON.parse(readFileSync({json.dumps(str(tmp / 'input.json'))}, 'utf8'));
        const model = createModel(spec);
        const r = model.score(win);
        if (r === null) {{
            console.log("NULL");
        }} else {{
            console.log(JSON.stringify(r));
        }}
        """
        proc = subprocess.run(
            ["node", "--input-type=module", "-e", js],
            capture_output=True, text=True,
        )

    if proc.returncode != 0:
        print(proc.stderr)
        raise RuntimeError("Node execution failed")

    out = proc.stdout.strip().splitlines()[-1]
    if out == "NULL":
        return None
    return json.loads(out)


def median5(win):
    """Width-5 centred median filter, matching smooth() in anomalyModel.js.

    score() conditions the window this way before normalising, so the numpy
    reference must too - otherwise the test compares a filtered pipeline with
    an unfiltered one and calls a correct implementation broken.
    """
    padded = np.pad(win, ((2, 2), (0, 0)), mode="edge")
    stacked = np.stack([padded[i:i + len(win)] for i in range(5)], axis=0)
    return np.median(stacked, axis=0).astype(np.float32)


def test_multiple_random_seeds():
    print("Testing ML parity across 5 random architectural seeds...")
    for seed in [1, 42, 123, 777, 9999]:
        window, n_feat, hidden, latent = 30, 2, 32, 8
        rng = np.random.default_rng(seed)
        dims = [(window * n_feat, hidden), (hidden, latent), (latent, hidden), (hidden, window * n_feat)]
        layers, mats = [], []
        for n_in, n_out in dims:
            W = (rng.standard_normal((n_out, n_in)) * 0.2).astype(np.float32)
            b = (rng.standard_normal(n_out) * 0.1).astype(np.float32)
            mats.append((W, b))
            layers.append({
                "in": n_in, "out": n_out,
                "W": [round(float(v), 6) for v in W.reshape(-1)],
                "b": [round(float(v), 6) for v in b],
            })
        acts = ["relu"] * (len(layers) - 1) + ["none"]
        mean = np.array([75.0, 96.0], dtype=np.float32)
        std = np.array([15.0, 3.0], dtype=np.float32)

        spec = {
            "features": ["HR", "SpO2"],
            "window": window,
            "normalisation": {"mean": mean.tolist(), "std": std.tolist()},
            "threshold": 0.5,
            "layers": layers,
            "activations": acts,
        }

        t = np.arange(window)
        hr = 75 + 10 * np.sin(t / 2.5)
        spo2 = 96 + 1.0 * np.cos(t / 3.5)
        win = np.stack([hr, spo2], axis=1).astype(np.float32)

        # Numpy forward pass
        x = ((median5(win) - mean) / std).reshape(-1)
        h = x.copy()
        for (W, b), a in zip(mats, acts):
            h = h @ W.T + b
            if a == "relu":
                h = np.maximum(h, 0.0)
        expected = float(((h - x) ** 2).mean())

        # JS forward pass
        input_dicts = [{"HR": float(r[0]), "SpO2": float(r[1])} for r in win]
        res = run_js_score(spec, input_dicts)

        assert res is not None, f"Expected non-null for seed {seed}"
        diff = abs(res["score"] - expected)
        assert diff < TOLERANCE, f"Parity failure for seed {seed}: diff={diff}"
    print("  PASS: All random seed architectures matched reference within tolerance.")


def test_short_and_missing_windows():
    print("Testing window edge cases (short, missing features, NaN)...")
    spec = {
        "features": ["HR", "SpO2"],
        "window": 5,
        "normalisation": {"mean": [80.0, 97.0], "std": [10.0, 2.0]},
        "threshold": 0.5,
        "layers": [
            {"in": 10, "out": 4, "W": [0.1]*40, "b": [0.0]*4},
            {"in": 4, "out": 10, "W": [0.1]*40, "b": [0.0]*10}
        ],
        "activations": ["relu", "none"],
    }

    # Short window (< 5)
    short = [{"HR": 80, "SpO2": 97}, {"HR": 80, "SpO2": 97}]
    assert run_js_score(spec, short) is None, "Expected null for short window"

    # Missing feature
    missing = [{"HR": 80} for _ in range(5)]
    assert run_js_score(spec, missing) is None, "Expected null for missing SpO2"

    # Null value inside window
    has_null = [{"HR": 80, "SpO2": 97} for _ in range(4)] + [{"HR": None, "SpO2": 97}]
    assert run_js_score(spec, has_null) is None, "Expected null for null vital"

    print("  PASS: Edge conditions handled gracefully (returned null).")


def main():
    test_multiple_random_seeds()
    test_short_and_missing_windows()
    print("\nALL ML INFERENCE ROBUSTNESS TESTS PASSED.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
