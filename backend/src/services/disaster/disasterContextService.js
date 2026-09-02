import config from '../../config.js';
import { Freshness, Provenance, Severity, SEVERITY_RANK, ATTRIBUTION } from './types.js';
import { distanceKm } from './sachetParser.js';
import { SachetDisasterSource, SampleDisasterSource } from './sources.js';

/**
 * Disaster context, behind an adapter so nothing upstream knows about HTTP.
 *
 * The health rules never depend on this. Every state it can be in — live,
 * cached, stale, sample, or nothing at all — leaves `evaluateReading` working
 * exactly as before. This only ever adds context to what the wearer is told.
 *
 * The one invariant worth stating out loud: **a bundled sample is never
 * reported as LIVE**. Freshness and provenance are tracked separately and
 * reconciled in `describe()`, so there is no path by which fixture data can be
 * presented as a live government feed.
 */
class DisasterContextService {
  constructor({ live = new SachetDisasterSource(), sample = new SampleDisasterSource() } = {}) {
    this.live = live;
    this.sample = sample;
    this.reset();
  }

  reset() {
    this.cache = {
      alerts: null,
      provenance: Provenance.NONE,
      /** When the body last changed. */
      fetchedAt: null,
      /** Last successful contact, including a 304. Drives freshness. */
      validatedAt: null,
      etag: null,
      capturedAt: null,
      skipped: 0,
      total: 0,
    };
    this.lastAttemptAt = null;
    this.lastError = null;
  }

  /**
   * Freshness of what we hold, reconciled against where it came from.
   *
   * A sample can be at most CACHED however recently it was read off disk,
   * because "how current is this file" is not the question a reader is asking.
   */
  freshness(now = new Date()) {
    const { alerts, provenance, validatedAt } = this.cache;
    if (!alerts || alerts.length === 0) {
      if (!alerts) return Freshness.UNAVAILABLE;
    }
    if (provenance === Provenance.NONE) return Freshness.UNAVAILABLE;

    if (provenance === Provenance.SAMPLE) {
      // Never LIVE. Age it against capture time so a months-old sample reads
      // as STALE rather than quietly passing as recent.
      const at = this.cache.fetchedAt;
      if (!at) return Freshness.CACHED;
      return now.getTime() - at.getTime() > config.disaster.maxAgeMs
        ? Freshness.STALE
        : Freshness.CACHED;
    }

    if (!validatedAt) return Freshness.UNAVAILABLE;
    const age = now.getTime() - validatedAt.getTime();
    if (age <= config.disaster.liveWindowMs) return Freshness.LIVE;
    if (age <= config.disaster.maxAgeMs) return Freshness.CACHED;
    return Freshness.STALE;
  }

  shouldRefresh(now = new Date()) {
    if (!config.disaster.enabled) return false;
    if (!this.lastAttemptAt) return true;
    return now.getTime() - this.lastAttemptAt.getTime() >= config.disaster.refreshMs;
  }

  /** Attempts a live fetch. Never throws; a failure just leaves the cache alone. */
  async refresh({ now = new Date(), language = config.disaster.language, force = false } = {}) {
    if (!config.disaster.enabled) return false;
    if (!force && !this.shouldRefresh(now)) return false;

    this.lastAttemptAt = now;
    try {
      const result = await this.live.load({ etag: this.cache.etag, language, now });

      if (result.notModified) {
        // Unchanged upstream: the data we hold is confirmed current.
        this.cache.validatedAt = result.validatedAt ?? now;
        this.lastError = null;
        return true;
      }

      this.cache = {
        alerts: result.alerts,
        provenance: Provenance.NETWORK,
        fetchedAt: result.fetchedAt ?? now,
        validatedAt: result.validatedAt ?? now,
        etag: result.etag ?? null,
        capturedAt: null,
        skipped: result.skipped ?? 0,
        total: result.total ?? 0,
      };
      this.lastError = null;
      return true;
    } catch (err) {
      // Offline, blocked, timed out, or the feed changed shape. Whatever we
      // already hold stays valid and simply ages into CACHED then STALE.
      this.lastError = err instanceof Error ? err.message : String(err);
      return false;
    }
  }

  /** Loads the bundled sample, only when nothing real has ever arrived. */
  async loadSample({ now = new Date(), language = config.disaster.language } = {}) {
    if (!config.disaster.allowSample) return false;
    if (this.cache.provenance === Provenance.NETWORK) return false;
    try {
      const result = await this.sample.load({ language, now });
      this.cache = {
        alerts: result.alerts,
        provenance: Provenance.SAMPLE,
        fetchedAt: result.fetchedAt,
        validatedAt: null,
        etag: null,
        capturedAt: result.capturedAt,
        skipped: result.skipped ?? 0,
        total: result.total ?? 0,
      };
      return true;
    } catch (err) {
      this.lastError = err instanceof Error ? err.message : String(err);
      return false;
    }
  }

  /**
   * The whole context, ready for an API response or a UI.
   *
   * @param {object} [opts]
   * @param {number} [opts.lat] wearer latitude — filters to nearby alerts
   * @param {number} [opts.lon]
   * @param {number} [opts.radiusKm]
   */
  describe({ lat, lon, radiusKm = config.disaster.radiusKm, now = new Date(), limit = 10 } = {}) {
    const freshness = this.freshness(now);
    const { provenance } = this.cache;
    const all = this.cache.alerts ?? [];

    const hasPoint = Number.isFinite(lat) && Number.isFinite(lon);
    const scoped = all
      .map((alert) => {
        const km =
          hasPoint && alert.centroid ? distanceKm({ lat, lon }, alert.centroid) : null;
        return { ...alert, distanceKm: km == null ? null : Math.round(km) };
      })
      // An alert with no centroid is kept: it may still apply, and dropping it
      // silently would be a false all-clear.
      .filter((alert) => !hasPoint || alert.distanceKm == null || alert.distanceKm <= radiusKm);

    const ranked = [...scoped].sort((a, b) => {
      const s = SEVERITY_RANK[b.severity] - SEVERITY_RANK[a.severity];
      if (s !== 0) return s;
      return b.startsAt.getTime() - a.startsAt.getTime();
    });

    const highest = ranked.length ? ranked[0].severity : Severity.UNKNOWN;
    const referenceAt =
      provenance === Provenance.SAMPLE ? this.cache.fetchedAt : this.cache.validatedAt;

    return {
      freshness,
      provenance,
      // The single field a UI should print for attribution. Adapters cannot
      // write their own wording, so no view can imply a source it lacks.
      attribution: ATTRIBUTION[provenance] ?? ATTRIBUTION[Provenance.NONE],
      isLive: freshness === Freshness.LIVE && provenance === Provenance.NETWORK,
      isSample: provenance === Provenance.SAMPLE,
      updatedAt: referenceAt ? referenceAt.toISOString() : null,
      ageMinutes: referenceAt
        ? Math.max(0, Math.round((now.getTime() - referenceAt.getTime()) / 60000))
        : null,
      capturedAt: this.cache.capturedAt,
      highestSeverity: ranked.length ? highest : null,
      count: scoped.length,
      totalInFeed: this.cache.total,
      unparseable: this.cache.skipped,
      radiusKm: hasPoint ? radiusKm : null,
      lastError: this.lastError,
      alerts: ranked.slice(0, limit).map((alert) => ({
        ...alert,
        startsAt: alert.startsAt.toISOString(),
        endsAt: alert.endsAt ? alert.endsAt.toISOString() : null,
      })),
    };
  }

  /**
   * Refresh if due, fall back to the sample only when nothing real exists,
   * then describe. This is the one call a route or the rules should need.
   */
  async get(opts = {}) {
    const now = opts.now ?? new Date();
    await this.refresh({ now, language: opts.language });
    if (!this.cache.alerts) await this.loadSample({ now, language: opts.language });
    return this.describe({ ...opts, now });
  }
}

export const disasterContext = new DisasterContextService();
export { DisasterContextService };
