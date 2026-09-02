import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import config from '../../config.js';
import { Provenance } from './types.js';
import { parseSachetPayload } from './sachetParser.js';

const here = dirname(fileURLToPath(import.meta.url));
const SAMPLE_PATH = join(here, '..', '..', '..', 'data', 'sachet_sample.json');

/**
 * Live NDMA SACHET adapter.
 *
 * Sends a conditional request when we hold an ETag, so an unchanged feed costs
 * a 304 instead of 70 KB. A 304 still counts as a successful validation: the
 * data we hold is confirmed current, which is what freshness is really asking.
 */
export class SachetDisasterSource {
  constructor({ url = config.disaster.url, timeoutMs = config.disaster.timeoutMs } = {}) {
    this.id = 'sachet';
    this.url = url;
    this.timeoutMs = timeoutMs;
  }

  async load({ etag = null, language = config.disaster.language, now = new Date() } = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const headers = { Accept: 'application/json' };
      if (etag) headers['If-None-Match'] = etag;

      const res = await fetch(this.url, { headers, signal: controller.signal });

      if (res.status === 304) {
        return {
          notModified: true,
          alerts: null,
          etag,
          provenance: Provenance.NETWORK,
          validatedAt: now,
        };
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const payload = await res.json();
      const { alerts, skipped, total } = parseSachetPayload(payload, { now, language });

      return {
        notModified: false,
        alerts,
        skipped,
        total,
        etag: res.headers.get('etag'),
        provenance: Provenance.NETWORK,
        fetchedAt: now,
        validatedAt: now,
      };
    } finally {
      clearTimeout(timer);
    }
  }
}

/**
 * Bundled real-format sample.
 *
 * Exists so the adapter chain, the parser and the UI can all be exercised with
 * no network — and so a demo has something to show. It reports
 * [Provenance.SAMPLE], which the context service refuses to ever label LIVE.
 */
export class SampleDisasterSource {
  constructor({ path = SAMPLE_PATH } = {}) {
    this.id = 'sample';
    this.path = path;
  }

  async load({ language = config.disaster.language, now = new Date() } = {}) {
    const file = JSON.parse(await readFile(this.path, 'utf8'));

    // The sample was captured at a fixed moment, so its alerts are long
    // expired. Keeping them means the freshness label does the honest work of
    // saying how old this is, rather than an empty list implying "all clear".
    const { alerts, skipped, total } = parseSachetPayload(file.alerts, {
      now,
      language,
      activeOnly: false,
    });

    return {
      notModified: false,
      alerts,
      skipped,
      total,
      etag: null,
      provenance: Provenance.SAMPLE,
      fetchedAt: file._captured_at ? new Date(file._captured_at) : null,
      validatedAt: null,
      capturedAt: file._captured_at ?? null,
    };
  }
}
