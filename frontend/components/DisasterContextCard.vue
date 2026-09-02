<script setup lang="ts">
/**
 * Official disaster context from NDMA SACHET.
 *
 * The rule this component exists to honour: never let cached or sample data
 * read as live. Provenance decides the wording; freshness only decides how
 * loudly it is caveated. There is deliberately no code path that prints "LIVE"
 * for anything the backend did not mark `isLive`.
 */
interface DisasterAlert {
  id: string
  hazard: string
  disasterType: string
  severity: 'severe' | 'moderate' | 'minor' | 'unknown'
  rawSeverity: string | null
  severityColour: string | null
  message: string
  area: string | null
  issuedBy: string
  startsAt: string
  endsAt: string | null
  distanceKm: number | null
}

interface DisasterContext {
  freshness: 'LIVE' | 'CACHED' | 'STALE' | 'UNAVAILABLE'
  provenance: string
  attribution: string
  isLive: boolean
  isSample: boolean
  updatedAt: string | null
  ageMinutes: number | null
  highestSeverity: string | null
  count: number
  radiusKm: number | null
  lastError: string | null
  alerts: DisasterAlert[]
}

const props = defineProps<{ context: DisasterContext | null }>()

/** "18 min ago" / "4h ago" / "2d ago". */
function ago(minutes: number | null): string {
  if (minutes == null) return 'unknown'
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.round(hours / 24)}d ago`
}

const statusLabel = computed(() => {
  const c = props.context
  if (!c || c.freshness === 'UNAVAILABLE') return 'UNAVAILABLE'
  // A sample is never labelled by freshness alone — it says what it is.
  if (c.isSample) return 'SAMPLE DATA'
  return c.freshness
})

const statusTone = computed(() => {
  const c = props.context
  if (!c || c.freshness === 'UNAVAILABLE') return 'faint'
  if (c.isSample) return 'warn'
  if (c.freshness === 'LIVE') return 'ok'
  if (c.freshness === 'CACHED') return 'accent'
  return 'warn'
})

/** The one line of provenance text. Comes from the backend, never invented here. */
const sourceLine = computed(() => props.context?.attribution ?? 'No disaster source')

const headline = computed(() => {
  const c = props.context
  if (!c || c.count === 0) return null
  return c.alerts[0] ?? null
})

const severityTone = (s: string) =>
  s === 'severe' ? 'crit' : s === 'moderate' ? 'warn' : 'accent'
</script>

<template>
  <section class="disaster">
    <header class="disaster__head">
      <div class="disaster__title">
        <AppIcon name="shield" :size="17" />
        <span>Disaster context</span>
      </div>
      <span class="pill" :class="`pill--${statusTone}`">{{ statusLabel }}</span>
    </header>

    <!-- Nothing at all: say so plainly rather than implying all-clear. -->
    <p v-if="!context || context.freshness === 'UNAVAILABLE'" class="disaster__empty">
      No official disaster information available offline.
      <span class="disaster__sub">Local health monitoring is unaffected.</span>
    </p>

    <template v-else>
      <div v-if="headline" class="disaster__lead">
        <span class="dot" :class="`dot--${severityTone(headline.severity)}`" />
        <div>
          <p class="disaster__event">
            {{ headline.disasterType }}
            <span v-if="headline.area" class="disaster__area">· {{ headline.area }}</span>
          </p>
          <p class="disaster__msg">{{ headline.message }}</p>
          <p class="disaster__meta">
            {{ headline.issuedBy }}
            <template v-if="headline.distanceKm != null"> · {{ headline.distanceKm }} km away</template>
          </p>
        </div>
      </div>

      <p v-else class="disaster__empty">
        No active alerts
        <template v-if="context.radiusKm"> within {{ context.radiusKm }} km</template>.
      </p>

      <p v-if="context.count > 1" class="disaster__more">
        +{{ context.count - 1 }} more active {{ context.count === 2 ? 'alert' : 'alerts' }} in range
      </p>

      <!-- Attribution and freshness, always shown together. -->
      <footer class="disaster__foot">
        <span class="disaster__source">Source: {{ sourceLine }}</span>
        <span class="disaster__age">Updated: {{ ago(context.ageMinutes) }}</span>
      </footer>

      <p v-if="context.isSample" class="disaster__caveat">
        Showing bundled sample data because the live NDMA feed could not be reached.
        This is not a live government alert.
      </p>
      <p v-else-if="context.freshness === 'STALE'" class="disaster__caveat">
        This information is older than we can vouch for. Treat it as out of date.
      </p>
    </template>
  </section>
</template>

<style scoped>
.disaster {
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--surface);
  padding: 15px 16px;
}

.disaster__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 12px;
}

.disaster__title {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--text-dim);
}

.pill {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.08em;
  padding: 3px 8px;
  border-radius: 30px;
  border: 1px solid transparent;
}
.pill--ok { color: var(--ok); background: var(--ok-dim); border-color: var(--ok); }
.pill--accent { color: var(--accent); background: var(--accent-dim); border-color: var(--accent); }
.pill--warn { color: var(--warn); background: var(--warn-dim); border-color: var(--warn); }
.pill--faint { color: var(--text-faint); border-color: var(--line-strong); }

.disaster__lead { display: flex; gap: 11px; align-items: flex-start; }

.dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  margin-top: 6px;
  flex: 0 0 auto;
}
.dot--crit { background: var(--crit); }
.dot--warn { background: var(--warn); }
.dot--accent { background: var(--accent); }

.disaster__event { margin: 0 0 3px; font-size: 15px; font-weight: 600; color: var(--text); }
.disaster__area { font-weight: 400; color: var(--text-dim); }
.disaster__msg { margin: 0 0 5px; font-size: 13px; line-height: 1.45; color: var(--text-dim); }
.disaster__meta { margin: 0; font-size: 11px; color: var(--text-faint); }

.disaster__more { margin: 10px 0 0; font-size: 12px; color: var(--text-dim); }

.disaster__empty { margin: 0; font-size: 13px; color: var(--text-dim); }
.disaster__sub { display: block; margin-top: 3px; font-size: 12px; color: var(--text-faint); }

.disaster__foot {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  gap: 6px;
  margin-top: 13px;
  padding-top: 10px;
  border-top: 1px solid var(--line);
  font-size: 11px;
  color: var(--text-faint);
}
.disaster__age { font-family: var(--mono); }

.disaster__caveat {
  margin: 10px 0 0;
  font-size: 11.5px;
  line-height: 1.45;
  color: var(--warn);
}
</style>
