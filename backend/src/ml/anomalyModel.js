/**
 * Autoencoder inference — dependency-free.
 *
 * The model is a 4-layer MLP of roughly 4k parameters, so running it by hand is
 * ~25 lines of arithmetic. That buys three things worth more than a framework:
 *   - no WASM download in a PWA that has to work offline
 *   - it runs unchanged in Node and in the browser (the on-device claim)
 *   - it ports to a C array for the ESP32 without an intermediate graph format
 *
 * Weights come from ml/export_weights.py. Do not hand-edit model.json.
 *
 * The score is reconstruction error: the autoencoder was trained only on
 * healthy physiology, so a window it cannot reproduce is unlike anything it was
 * shown. High error means "this does not look like normal", NOT "this is
 * disease X" — the model has no diagnostic labels and cannot name a condition.
 */

/** @typedef {{layers: Array, activations: string[], normalisation: {mean: number[], std: number[]}, threshold: number, features: string[], window: number}} ModelSpec */

export function createModel(spec) {
  const { layers, activations, normalisation, threshold, features, window } = spec;
  const { mean, std } = normalisation;

  const nIn = layers[0].in;
  if (nIn !== window * features.length) {
    throw new Error(
      `model.json is inconsistent: first layer takes ${nIn} inputs but window*features = ${window * features.length}`
    );
  }

  // Pre-flatten the weights into typed arrays once, at load.
  const compiled = layers.map((l) => ({
    inDim: l.in,
    outDim: l.out,
    W: Float32Array.from(l.W),
    b: Float32Array.from(l.b),
  }));

  /** y = ReLU?(W x + b), W stored row-major as (out, in). */
  function forward(input) {
    let h = input;
    for (let li = 0; li < compiled.length; li++) {
      const { inDim, outDim, W, b } = compiled[li];
      const out = new Float32Array(outDim);
      for (let o = 0; o < outDim; o++) {
        let sum = b[o];
        const row = o * inDim;
        for (let i = 0; i < inDim; i++) sum += W[row + i] * h[i];
        out[o] = activations[li] === 'relu' ? (sum > 0 ? sum : 0) : sum;
      }
      h = out;
    }
    return h;
  }

  /**
   * @param {Array<Record<string, number|null>>} samples oldest-first, length >= window
   * @returns {{score:number, anomalous:boolean, ratio:number}|null} null when the
   *          window is not yet full or a required vital is missing
   */
  function score(samples) {
    if (!Array.isArray(samples) || samples.length < window) return null;

    const recent = smooth(samples.slice(-window), features);
    if (!recent) return null;
    const x = new Float32Array(window * features.length);

    let k = 0;
    for (let t = 0; t < window; t++) {
      for (let f = 0; f < features.length; f++) {
        const v = recent[t][features[f]];
        if (v === null || v === undefined || Number.isNaN(v)) return null;
        // Same flattening order as training: time-major, features interleaved.
        const s = std[f] || 1e-6;
        x[k] = (v - mean[f]) / s;
        k++;
      }
    }

    const out = forward(x);

    let sum = 0;
    for (let i = 0; i < x.length; i++) {
      const d = out[i] - x[i];
      sum += d * d;
    }
    const err = sum / x.length;

    return {
      score: err,
      anomalous: err >= threshold,
      // How far past the threshold, for display. 1.0 == exactly at it.
      ratio: err / threshold,
    };
  }

  return { score, threshold, features, window, spec };
}

/**
 * Width-5 centred median filter over the window, applied before scoring.
 *
 * The model was trained on BIDMC numerics, where SpO2 is flat 95.7% of the
 * time and HR 72.2% - it effectively learned that these vitals do not move
 * sample-to-sample inside 30 seconds. A real MAX30102 and the simulator both
 * emit integers that flip by one constantly, and the autoencoder cannot
 * reproduce that jitter, so reconstruction error came from sensor noise rather
 * than from physiology. Measured on normal windows (HR 68-84, SpO2 96-98),
 * a one-count SpO2 flicker alone drove 93% of them past the anomaly threshold
 * and 44% past ML_ALERT_RATIO - false alerts on healthy readings.
 *
 * A median is the right filter: it removes single-sample spikes outright while
 * leaving a genuine step edge intact, so a real desaturation still arrives at
 * full amplitude. On the training data itself it is close to a no-op - SpO2 is
 * unchanged in 99.7% of samples - so this conditions serve-time input to look
 * like train-time input rather than introducing a new mismatch. Measured
 * after: 0% false alerts on normal windows, hypoxia still detected 100%.
 *
 * Keep this identical to the smoothing in ml/prepare_data.py.
 */
function smooth(win, features) {
  const n = win.length;
  if (n === 0) return null;
  const half = 2;
  const out = new Array(n);
  const scratch = new Array(2 * half + 1);

  for (let i = 0; i < n; i++) {
    const sample = {};
    for (const f of features) {
      let m = 0;
      for (let j = -half; j <= half; j++) {
        const idx = Math.min(n - 1, Math.max(0, i + j));
        const v = win[idx][f];
        if (v === null || v === undefined || Number.isNaN(v)) return null;
        scratch[m++] = v;
      }
      scratch.sort((a, b) => a - b);
      sample[f] = scratch[half];
    }
    out[i] = sample;
  }
  return out;
}

/**
 * Fixed-length rolling buffer of the vitals the model needs, one per device.
 * Samples with a bad PPG signal are skipped rather than stored — feeding the
 * model values the app itself flags as untrustworthy would manufacture
 * anomalies out of sensor dropout.
 */
export function createBuffer(features, window) {
  const buffers = new Map();

  return {
    push(deviceId, reading) {
      if (reading.signalOk === false) return;

      const sample = {};
      for (const f of features) {
        const v = f === 'HR' ? reading.heartRate : f === 'SpO2' ? reading.spo2 : reading[f];
        if (v === null || v === undefined) return; // incomplete — skip
        sample[f] = v;
      }

      const buf = buffers.get(deviceId) ?? [];
      buf.push(sample);
      if (buf.length > window) buf.splice(0, buf.length - window);
      buffers.set(deviceId, buf);
    },

    get(deviceId) {
      return buffers.get(deviceId) ?? [];
    },

    reset(deviceId) {
      if (deviceId) buffers.delete(deviceId);
      else buffers.clear();
    },
  };
}
