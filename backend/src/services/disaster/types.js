/**
 * Shared vocabulary for the disaster-context adapters.
 *
 * Two axes are tracked separately and must never be collapsed:
 *
 *   freshness  — how old the data is
 *   provenance — where it came from
 *
 * Keeping them apart is what makes "never present fixture data as live
 * government data" enforceable rather than a convention. A bundled sample is
 * still a sample when it is thirty seconds old, so provenance decides the
 * label and freshness only decides how loudly we caveat it.
 */

export const Freshness = {
  /** Fetched from the source successfully, within the live window. */
  LIVE: 'LIVE',
  /** Real data from a previous successful fetch, still inside its usable age. */
  CACHED: 'CACHED',
  /** Real data, but older than we are willing to call current. */
  STALE: 'STALE',
  /** Nothing usable at all. */
  UNAVAILABLE: 'UNAVAILABLE',
};

export const Provenance = {
  /** Retrieved over the network from NDMA SACHET. */
  NETWORK: 'ndma_sachet',
  /** A captured real-format response shipped with the app. Never "live". */
  SAMPLE: 'bundled_sample',
  /** No data. */
  NONE: 'none',
};

/** Canonical severity, mapped from SACHET's inconsistent fields. */
export const Severity = {
  SEVERE: 'severe',
  MODERATE: 'moderate',
  MINOR: 'minor',
  UNKNOWN: 'unknown',
};

export const SEVERITY_RANK = {
  [Severity.SEVERE]: 3,
  [Severity.MODERATE]: 2,
  [Severity.MINOR]: 1,
  [Severity.UNKNOWN]: 0,
};

/**
 * The contract every disaster source implements.
 *
 * @typedef {object} DisasterSource
 * @property {string} id
 * @property {() => Promise<{alerts: object[], fetchedAt: Date, provenance: string, etag: string|null, notModified?: boolean}>} load
 */

/**
 * Human-facing attribution. Kept here so no adapter can invent its own wording
 * and accidentally imply a source it does not have.
 */
export const ATTRIBUTION = {
  [Provenance.NETWORK]: 'NDMA SACHET (sachet.ndma.gov.in)',
  [Provenance.SAMPLE]: 'Bundled sample of NDMA SACHET data — not live',
  [Provenance.NONE]: 'No disaster source available',
};
