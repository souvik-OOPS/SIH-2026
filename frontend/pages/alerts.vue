<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import {
  useHealth,
  SEVERITY_COLOR,
  SEVERITY_ICON,
  ALERT_LABEL,
  timeAgo,
  clockTime,
  type Alert,
} from '~/composables/useHealth'

const { alerts, loadAlerts, acknowledge, now, unacknowledged } = useHealth()

useHead({ title: 'Alerts — Health Companion' })

const filter = ref<'all' | 'critical' | 'open'>('all')

onMounted(loadAlerts)

const criticalCount = computed(() => alerts.value.filter((a: Alert) => a.severity === 'critical').length)

const shown = computed(() => {
  if (filter.value === 'critical') return alerts.value.filter((a: Alert) => a.severity === 'critical')
  if (filter.value === 'open') return alerts.value.filter((a: Alert) => !a.acknowledged)
  return alerts.value
})

/** Turn the stored snapshot into the numbers worth showing, in a fixed order. */
function snapshotRows(snap: Record<string, unknown> | undefined) {
  if (!snap) return []
  const spec: [string, string, string][] = [
    ['heartRate', 'HR', 'bpm'],
    ['restingHr', 'Resting', 'bpm'],
    ['spo2', 'SpO₂', '%'],
    ['ambientTemp', 'Ambient', '°C'],
    ['humidity', 'Humidity', '%'],
    ['accelMagnitude', 'Impact', 'g'],
  ]
  return spec
    .filter(([k]) => snap[k] !== null && snap[k] !== undefined)
    .map(([k, label, unit]) => ({ label, value: snap[k] as number, unit }))
}
</script>

<template>
  <div>
    <header class="topbar">
      <div>
        <h1>Incident Log &amp; Alerts</h1>
        <p class="sub">
          {{ alerts.length }} logged &middot; {{ unacknowledged }} unacknowledged
        </p>
      </div>
      <button class="btn small ghost" @click="loadAlerts">
        <AppIcon name="refresh" :size="13" /> Refresh
      </button>
    </header>

    <div class="row" style="margin-bottom: 14px; gap: 8px">
      <button class="btn small" :class="{ active: filter === 'all' }" @click="filter = 'all'">
        All ({{ alerts.length }})
      </button>
      <button class="btn small" :class="{ active: filter === 'open' }" @click="filter = 'open'">
        Unacknowledged ({{ unacknowledged }})
      </button>
      <button class="btn small" :class="{ active: filter === 'critical' }" @click="filter = 'critical'">
        Critical ({{ criticalCount }})
      </button>
    </div>

    <div v-if="!shown.length" class="card" style="text-align: center; padding: 48px 16px">
      <AppIcon name="check" :size="28" style="color: var(--ok); margin-bottom: 12px" />
      <p class="muted" style="margin: 0; font-size: 14px">
        <template v-if="alerts.length">No alerts matching this filter.</template>
        <template v-else>All clear. Telemetry is within safe physiological bounds.</template>
      </p>
    </div>

    <div v-else class="trends-grid" style="gap: 12px">
      <article
        v-for="a in shown"
        :key="a._id"
        class="card"
        style="margin-bottom: 0; transition: border-color 0.2s ease, transform 0.15s ease"
        :style="{
          borderLeft: `3px solid ${SEVERITY_COLOR[a.severity]}`,
          opacity: a.acknowledged ? 0.65 : 1,
          boxShadow: !a.acknowledged && a.severity === 'critical' ? '0 0 16px rgba(255, 79, 99, 0.15)' : 'none',
        }"
      >
        <div class="spread" style="align-items: flex-start">
          <div style="min-width: 0">
            <div class="row" style="gap: 8px; flex-wrap: nowrap">
              <AppIcon
                :name="SEVERITY_ICON[a.severity]"
                :size="18"
                :style="{ color: SEVERITY_COLOR[a.severity], marginTop: '1px' }"
              />
              <span style="font-weight: 600; font-size: 14px; letter-spacing: -0.01em">{{ a.message }}</span>
            </div>
            <p class="muted" style="margin: 6px 0 0; line-height: 1.5; font-size: 12.5px">{{ a.detail }}</p>
          </div>
          <span class="faint mono" style="white-space: nowrap; font-size: 11px">{{ timeAgo(a.timestamp, now) }}</span>
        </div>

        <div v-if="snapshotRows(a.snapshot).length" class="row" style="margin-top: 12px; gap: 6px">
          <span v-for="s in snapshotRows(a.snapshot)" :key="s.label" class="pill mono" style="font-size: 10.5px">
            {{ s.label }} {{ s.value }}{{ s.unit }}
          </span>
        </div>

        <div class="spread" style="margin-top: 14px; padding-top: 10px; border-top: 1px solid var(--line)">
          <div class="row" style="gap: 8px">
            <span class="faint">{{ ALERT_LABEL[a.type] ?? a.type }}</span>
            <span class="faint">&middot; {{ clockTime(a.timestamp) }}</span>
            <span v-if="a.smsSent" class="faint row" style="gap: 4px; color: var(--ok)">
              <AppIcon name="message" :size="12" /> SMS delivered
            </span>
            <span v-else-if="a.smsError" class="faint" style="color: var(--crit)">&middot; SMS failed</span>
            <span v-else-if="a.smsNote" class="faint">&middot; SMS held ({{ a.smsNote }})</span>
          </div>
          <button v-if="!a.acknowledged" class="btn small primary" @click="acknowledge(a._id)">
            Acknowledge
          </button>
          <span v-else class="faint row" style="gap: 4px; color: var(--ok)">
            <AppIcon name="check" :size="12" /> Acknowledged
          </span>
        </div>
      </article>
    </div>
  </div>
</template>
