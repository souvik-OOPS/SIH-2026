import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createModel, createBuffer } from '../ml/anomalyModel.js';

/**
 * Wraps the learned anomaly detector so the rest of the backend never has to
 * care whether a model is present.
 *
 * The model is OPTIONAL by design. A fresh clone has no model.json until
 * someone runs the training pipeline, and the app must still work — the rule
 * engine is the floor, the model is an additional signal on top. Everything
 * here degrades to "no opinion" rather than throwing.
 *
 * Disable explicitly with ML_ENABLED=false.
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const MODEL_PATH = join(HERE, '..', 'ml', 'model.json');

let model = null;
let buffer = null;
let status = 'not_loaded';

function load() {
  if (process.env.ML_ENABLED === 'false') {
    status = 'disabled';
    return;
  }
  if (!existsSync(MODEL_PATH)) {
    status = 'no_model';
    console.log('[ml] no model.json — running on rules only. Train one: see ml/README.md');
    return;
  }

  try {
    const spec = JSON.parse(readFileSync(MODEL_PATH, 'utf8'));
    model = createModel(spec);
    buffer = createBuffer(model.features, model.window);
    status = 'ready';
    const m = spec.metrics ?? {};
    console.log(
      `[ml] model loaded — ${model.features.join('+')} over ${model.window}s` +
        (m.roc_auc ? `, test AUC ${Number(m.roc_auc).toFixed(3)}` : '')
    );
  } catch (err) {
    status = 'error';
    console.warn(`[ml] failed to load model (${err.message}) — running on rules only.`);
  }
}

load();

export const mlStatus = () => ({
  status,
  ready: status === 'ready',
  features: model?.features ?? null,
  window: model?.window ?? null,
  threshold: model?.threshold ?? null,
  metrics: model?.spec?.metrics ?? null,
});

export function resetMlBuffer(deviceId) {
  buffer?.reset(deviceId);
}

/**
 * Feed one reading and score the window it completes.
 *
 * @returns {null | {score:number, ratio:number, anomalous:boolean, samples:number}}
 *          null when there is no model, or the window is not yet full.
 */
export function scoreReading(reading) {
  if (status !== 'ready') return null;

  buffer.push(reading.deviceId, reading);
  const window = buffer.get(reading.deviceId);

  const result = model.score(window);
  if (!result) return null;

  return { ...result, samples: window.length };
}
