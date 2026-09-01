<script setup lang="ts">
import type { Reading } from '~/composables/useHealth'
import type { Series } from '~/components/TrendChart.vue'

const { loadHistory, latest } = useHealth()

useHead({ title: 'Trends — Health Companion' })

const RANGES = [
  { label: '15m', minutes: 15 },
  { label: '1h', minutes: 60 },
  { label: '6h', minutes: 360 },
  { label: '24h', minutes: 1440 },
]

const range = ref(60)
const rows = ref<Reading[]>([])
const loading = ref(true)

async function refresh() {
  loading.value = true
  rows.value = await loadHistory(range.value)
  loading.value = false
}

watch(range, refresh)
onMounted(refresh)

// Pull in new samples as they arrive, but only while looking at a short window —
// on a 24h view one extra point is invisible and the redraw is wasted work.
watch(latest, (r) => {
  if (r && range.value <= 60) rows.value = [...rows.value, r].slice(-1500)
})

/**
 * A 6h window at 1 Hz is ~21,000 points. Chart.js will render it, badly.
 * Bucket down to a target count by averaging, which also smooths sensor noise.
 */
const TARGET_POINTS = 180

/**
 * Blank out PPG-derived values on samples the firmware flagged as bad signal.
 * Plotting them puts deep spikes in the chart that the dashboard is already
 * greying out as untrustworthy — the two views should not disagree.
 */
const cleaned = computed(() =>
  rows.value.map((r) => (r.signalOk === false ? { ...r, heartRate: null, spo2: null } : r))
)

const sampled = computed(() => {
  const src = cleaned.value
  if (src.length <= TARGET_POINTS) return src

  const bucketSize = Math.ceil(src.length / TARGET_POINTS)
  const out: Reading[] = []

  for (let i = 0; i < src.length; i += bucketSize) {
    const bucket = src.slice(i, i + bucketSize)
    const avg = (key: keyof Reading) => {
      const vals = bucket.map((b) => b[key]).filter((v): v is number => typeof v === 'number')
      return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null
    }
    out.push({
      ...bucket[bucket.length - 1],
      heartRate: avg('heartRate'),
      spo2: avg('spo2'),
      ambientTemp: avg('ambientTemp'),
      humidity: avg('humidity'),
      heatIndex: avg('heatIndex'),
    })
  }
  return out
})

const labels = computed(() =>
  sampled.value.map((r) =>
    new Date(r.timestamp).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', hour12: false })
  )
)

const round = (n: number | null) => (n == null ? null : Math.round(n * 10) / 10)

const vitalsSeries = computed<Series[]>(() => [
  { label: 'Heart rate (bpm)', data: sampled.value.map((r) => round(r.heartRate)), color: '#ff4f63', axis: 'y' },
  { label: 'SpO₂ (%)', data: sampled.value.map((r) => round(r.spo2)), color: '#46b6f0', axis: 'y1' },
])

const envSeries = computed<Series[]>(() => [
  { label: 'Ambient (°C)', data: sampled.value.map((r) => round(r.ambientTemp)), color: '#f4783c', axis: 'y' },
  { label: 'Heat index (°C)', data: sampled.value.map((r) => round(r.heatIndex)), color: '#ff4f63', axis: 'y', dashed: true },
  { label: 'Humidity (%)', data: sampled.value.map((r) => round(r.humidity)), color: '#46b6f0', axis: 'y1' },
])

/* --------------------------------- summary -------------------------------- */

function stats(key: 'heartRate' | 'spo2' | 'heatIndex') {
  const vals = cleaned.value.map((r) => r[key]).filter((v): v is number => typeof v === 'number')
  if (!vals.length) return null
  const sum = vals.reduce((a, b) => a + b, 0)
  return {
    min: Math.round(Math.min(...vals) * 10) / 10,
    max: Math.round(Math.max(...vals) * 10) / 10,
    avg: Math.round((sum / vals.length) * 10) / 10,
  }
}

const summary = computed(() => ({
  hr: stats('heartRate'),
  spo2: stats('spo2'),
  heat: stats('heatIndex'),
}))
</script>

<template>
  <div>
    <header class="topbar">
      <div>
        <h1>Trends</h1>
        <p class="sub"><span class="mono">{{ rows.length }}</span> readings in this window</p>
      </div>
    </header>

    <div class="row" style="margin-bottom: 12px">
      <button
        v-for="r in RANGES"
        :key="r.minutes"
        class="btn small"
        :class="{ active: range === r.minutes }"
        @click="range = r.minutes"
      >
        {{ r.label }}
      </button>
    </div>

    <div v-if="loading" class="card"><p class="empty" style="padding: 20px">Loading…</p></div>

    <div v-else-if="!rows.length" class="card">
      <p class="empty">
        No readings in this window.<br >
        Run <span class="mono">npm run simulate</span> in the backend folder.
      </p>
    </div>

    <template v-else>
      <section class="card">
        <p class="card-title">Vitals</p>
        <TrendChart :labels="labels" :series="vitalsSeries" y-label="bpm" y1-label="%" />
      </section>

      <section class="card">
        <p class="card-title">Environment &amp; apparent temperature</p>
        <TrendChart :labels="labels" :series="envSeries" y-label="°C" y1-label="% RH" />
        <p class="note">
          The dashed line is heat index — what the air actually feels like once humidity blocks
          evaporative cooling. It runs well above dry-bulb temperature in humid conditions.
        </p>
      </section>

      <section class="card">
        <p class="card-title">Window summary</p>
        <div class="grid-2" style="margin: 0">
          <div v-if="summary.hr">
            <div class="stat-key">Heart rate</div>
            <div class="stat-val">{{ summary.hr.avg }}<span class="unit-sm">bpm avg</span></div>
            <div class="stat-sub">{{ summary.hr.min }}–{{ summary.hr.max }}</div>
          </div>
          <div v-if="summary.spo2">
            <div class="stat-key">Blood oxygen</div>
            <div class="stat-val">{{ summary.spo2.avg }}<span class="unit-sm">% avg</span></div>
            <div class="stat-sub">low {{ summary.spo2.min }}%</div>
          </div>
        </div>
        <div v-if="summary.heat" class="rule" />
        <div v-if="summary.heat">
          <div class="stat-key">Heat index</div>
          <div class="stat-val" :style="{ color: summary.heat.max >= 51 ? '#ff4f63' : summary.heat.max >= 39 ? '#f0a742' : 'inherit' }">
            {{ summary.heat.max }}<span class="unit-sm">°C peak</span>
          </div>
          <div class="stat-sub">avg {{ summary.heat.avg }}°C</div>
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.unit-sm {
  margin-left: 5px;
  font-family: var(--font);
  font-size: 10.5px;
  font-weight: 500;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--text-faint);
}
</style>
