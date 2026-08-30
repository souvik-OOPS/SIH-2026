<script setup lang="ts">
const { alerts, loadAlerts, acknowledge, now, unacknowledged } = useHealth()

useHead({ title: 'Alerts — Health Companion' })

const filter = ref<'all' | 'critical' | 'open'>('all')

onMounted(loadAlerts)

const shown = computed(() => {
  if (filter.value === 'critical') return alerts.value.filter((a) => a.severity === 'critical')
  if (filter.value === 'open') return alerts.value.filter((a) => !a.acknowledged)
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
        <h1>Alerts</h1>
        <p class="sub">
          {{ alerts.length }} total · {{ unacknowledged }} unacknowledged
        </p>
      </div>
      <button class="btn small ghost" @click="loadAlerts">
        <AppIcon name="refresh" :size="13" /> Refresh
      </button>
    </header>

    <div class="row" style="margin-bottom: 12px">
      <button class="btn small" :class="{ active: filter === 'all' }" @click="filter = 'all'">All</button>
      <button class="btn small" :class="{ active: filter === 'open' }" @click="filter = 'open'">Unacknowledged</button>
      <button class="btn small" :class="{ active: filter === 'critical' }" @click="filter = 'critical'">Critical</button>
    </div>

    <div v-if="!shown.length" class="card">
      <p class="empty">
        <template v-if="alerts.length">Nothing matches this filter.</template>
        <template v-else>No alerts yet. The wearer's vitals have stayed in range.</template>
      </p>
    </div>

    <article
      v-for="a in shown"
      :key="a._id"
      class="card"
      :style="{ borderLeft: `3px solid ${SEVERITY_COLOR[a.severity]}`, opacity: a.acknowledged ? 0.62 : 1 }"
    >
      <div class="spread" style="align-items: flex-start">
        <div style="min-width: 0">
          <div class="row" style="gap: 8px; flex-wrap: nowrap">
            <AppIcon
              :name="SEVERITY_ICON[a.severity]"
              :size="17"
              :style="{ color: SEVERITY_COLOR[a.severity], marginTop: '1px' }"
            />
            <span style="font-weight: 600; font-size: 14px; letter-spacing: -0.005em">{{ a.message }}</span>
          </div>
          <p class="muted" style="margin: 6px 0 0; line-height: 1.5">{{ a.detail }}</p>
        </div>
        <span class="faint mono" style="white-space: nowrap">{{ timeAgo(a.timestamp, now) }}</span>
      </div>

      <div v-if="snapshotRows(a.snapshot).length" class="row" style="margin-top: 11px; gap: 6px">
        <span v-for="s in snapshotRows(a.snapshot)" :key="s.label" class="pill mono">
          {{ s.label }} {{ s.value }}{{ s.unit }}
        </span>
      </div>

      <div class="spread" style="margin-top: 12px">
        <div class="row" style="gap: 7px">
          <span class="faint">{{ ALERT_LABEL[a.type] ?? a.type }}</span>
          <span class="faint">· {{ clockTime(a.timestamp) }}</span>
          <span v-if="a.smsSent" class="faint row" style="gap: 4px">
            <AppIcon name="message" :size="12" /> SMS sent
          </span>
          <span v-else-if="a.smsError" class="faint">· SMS failed</span>
          <span v-else-if="a.smsNote" class="faint">· SMS held: {{ a.smsNote }}</span>
        </div>
        <button v-if="!a.acknowledged" class="btn small" @click="acknowledge(a._id)">Acknowledge</button>
        <span v-else class="faint row" style="gap: 4px"><AppIcon name="check" :size="12" /> Acknowledged</span>
      </div>
    </article>
  </div>
</template>
