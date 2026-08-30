<script setup lang="ts">
const {
  latest, trail, device, banner, connected, deviceOnline, now,
  acknowledge, enableNotifications, activeCritical,
} = useHealth()

useHead({ title: 'Live — Health Companion' })

const derived = computed(() => latest.value?.derived ?? null)
const ambient = computed(() => latest.value?.ambient ?? null)

/* --------------------------- vital status colouring ------------------------ */

const hrStatus = computed(() => {
  const hr = latest.value?.heartRate
  if (hr == null) return 'ok'
  if (hr > 130 || hr < 45) return 'crit'
  if (hr > 110 || hr < 52) return 'warn'
  return 'ok'
})

const spo2Status = computed(() => {
  const s = latest.value?.spo2
  if (s == null) return 'ok'
  if (s < 90) return 'crit'
  if (s < 94) return 'warn'
  return 'ok'
})

/* --------------------------------- meters --------------------------------- */

// Map the heat index onto the NOAA band range so the bar position means something.
const heatPct = computed(() => {
  const hi = derived.value?.heatIndex
  if (hi == null) return 0
  return Math.min(100, Math.max(0, ((hi - 20) / (58 - 20)) * 100))
})

const heatColor = computed(() => HEAT_BAND_COLOR[derived.value?.heatBand ?? 'unknown'])

const strainPct = computed(() => Math.min(100, (derived.value?.strain ?? 0) * 100))

const strainColor = computed(() => {
  const p = strainPct.value
  if (p >= 70) return '#ff4f63'
  if (p >= 45) return '#f0a742'
  return '#2fd39f'
})

/* -------------------------------- sparkline -------------------------------- */

const hrTrail = computed(() =>
  trail.value.filter((r) => r.signalOk !== false).slice(-60).map((r) => r.heartRate)
)

const restingHr = computed(() => derived.value?.restingHr ?? null)

/* ------------------------------ notifications ------------------------------ */

const notifState = ref<'unknown' | 'granted' | 'denied'>('unknown')

onMounted(() => {
  if (typeof Notification !== 'undefined') {
    notifState.value = Notification.permission === 'granted' ? 'granted'
      : Notification.permission === 'denied' ? 'denied' : 'unknown'
  }
})

async function askNotifications() {
  const ok = await enableNotifications()
  notifState.value = ok ? 'granted' : 'denied'
}

/* --------------------------------- labels ---------------------------------- */

const wearer = computed(() => device.value?.wearerName || device.value?.deviceId || 'Wearer')

const profileLabel: Record<string, string> = {
  general: 'General',
  elderly: 'Elderly',
  outdoor_worker: 'Outdoor worker',
  chronic_condition: 'Chronic condition',
}

const lastSeenText = computed(() =>
  latest.value ? timeAgo(latest.value.timestamp, now.value) : 'no data yet'
)

const envSourceLabel = computed(() => {
  const s = derived.value?.envSource
  if (s === 'device') return 'on-device sensor'
  if (s === 'openweather') return 'weather API'
  if (s === 'demo-override' || s === 'mock' || s === 'override') return 'simulated'
  return 'unavailable'
})

/* --------------------------- learned model readout ------------------------- */

// null until the model has a full window (or when no model is installed).
const mlRatio = computed(() => derived.value?.mlRatio ?? null)

// The bar is the score as a fraction of the alert threshold; 100% == at it.
const mlPct = computed(() => Math.min(100, (mlRatio.value ?? 0) * 100))

const mlColor = computed(() => {
  const r = mlRatio.value
  if (r == null) return '#616e83'
  if (r >= 1.6) return '#ff4f63'
  if (r >= 1.0) return '#f0a742'
  return '#2fd39f'
})

const mlLabel = computed(() => {
  const r = mlRatio.value
  if (r == null) return 'Warming up'
  if (r >= 1.6) return 'Unusual'
  if (r >= 1.0) return 'Borderline'
  return 'Typical'
})

const motionLabel = computed(() => {
  const m = latest.value?.motion
  return !m || m === 'unknown' ? null : m
})
</script>

<template>
  <div>
    <header class="topbar">
      <div>
        <h1>{{ wearer }}</h1>
        <p class="sub">{{ profileLabel[device?.profile ?? 'general'] }} &middot; {{ lastSeenText }}</p>
      </div>
      <span class="pill">
        <span class="dot" :class="deviceOnline ? 'live' : 'down'" />
        {{ deviceOnline ? 'Live' : connected ? 'No signal' : 'Offline' }}
      </span>
    </header>

    <AlertBanner v-if="banner" :alert="banner" @ack="acknowledge" />

    <div v-if="!latest" class="card">
      <p class="card-title">Waiting for the device</p>
      <p class="muted" style="margin: 0 0 14px; line-height: 1.55">
        No readings yet. Start the wearable, or run the simulator:
      </p>
      <p class="mono faint" style="margin: 0; word-break: break-all">npm run simulate</p>
    </div>

    <template v-else>
      <!-- Primary vitals -->
      <div class="grid-2">
        <VitalTile
          label="Heart rate"
          icon="heart"
          :value="latest.heartRate"
          unit="bpm"
          :status="hrStatus"
          :stale="latest.signalOk === false"
          :beat="latest.heartRate"
          :foot="restingHr ? `Resting baseline ${restingHr} bpm` : 'Learning baseline…'"
        />
        <VitalTile
          label="Blood oxygen"
          icon="droplet"
          :value="latest.spo2"
          unit="%"
          :status="spo2Status"
          :stale="latest.signalOk === false"
          :foot="latest.signalOk === false ? 'Signal poor — motion' : 'Peripheral SpO₂'"
        />
      </div>

      <div class="grid-2">
        <VitalTile
          label="Body temp"
          icon="thermometer"
          :value="latest.bodyTemp"
          unit="°C"
          :foot="latest.bodyTemp == null ? 'Sensor not fitted' : 'Skin contact'"
        />
        <VitalTile
          label="Movement"
          icon="motion"
          :value="motionLabel"
          :foot="latest.accelMagnitude != null ? `${latest.accelMagnitude.toFixed(2)} g` : ''"
        />
      </div>

      <!-- Heart-rate trace -->
      <section class="card">
        <div class="spread" style="margin-bottom: 12px">
          <p class="card-title" style="margin: 0">Heart rate &middot; last 60 samples</p>
          <span class="faint mono">{{ clockTime(latest.timestamp) }}</span>
        </div>
        <SparkLine :points="hrTrail" color="#ff4f63" :height="56" />
      </section>

      <!-- The differentiator: environment cross-referenced with the body -->
      <section class="card">
        <p class="card-title">Environmental risk</p>

        <div class="spread" style="margin-bottom: 8px">
          <span class="metric-label">Heat index</span>
          <span class="readout" :style="{ color: heatColor }">
            {{ derived?.heatIndex != null ? `${derived.heatIndex}°C` : '––' }}
            <span class="band">{{ derived?.heatBandLabel }}</span>
          </span>
        </div>
        <div class="meter">
          <span :style="{ width: `${heatPct}%`, background: heatColor }" />
          <span class="ticks"><i /><i /><i /><i /></span>
        </div>
        <div class="scale">
          <span>Safe</span><span>Caution</span><span>Danger</span><span>Extreme</span>
        </div>
        <p class="note">
          Apparent temperature from {{ latest.ambientTemp ?? '––' }}°C at {{ latest.humidity ?? '––' }}% RH
          ({{ envSourceLabel }}).
          <template v-if="derived?.heatIndexExtrapolated">Beyond the NWS chart's validated range.</template>
        </p>

        <div class="rule" />

        <div class="spread" style="margin-bottom: 8px">
          <span class="metric-label">Cardiovascular strain</span>
          <span class="readout" :style="{ color: strainColor }">{{ strainPct.toFixed(0) }}%</span>
        </div>
        <div class="meter">
          <span :style="{ width: `${strainPct}%`, background: strainColor }" />
        </div>
        <p class="note">
          Heart rate as a share of reserve above this wearer's own resting baseline.
          Heat risk is judged on this <em>and</em> the environment together.
        </p>

        <template v-if="mlRatio != null">
          <div class="rule" />
          <div class="spread" style="margin-bottom: 8px">
            <span class="metric-label">Learned baseline model</span>
            <span class="readout" :style="{ color: mlColor }">
              {{ mlRatio.toFixed(2) }}x
              <span class="band">{{ mlLabel }}</span>
            </span>
          </div>
          <div class="meter">
            <span :style="{ width: `${mlPct}%`, background: mlColor }" />
          </div>
          <p class="note">
            On-device autoencoder trained on real patient vitals. Scores how far this 30-second window sits
            from normal physiology — a deviation signal, not a diagnosis.
          </p>
        </template>

        <template v-if="ambient?.aqi != null">
          <div class="rule" />
          <div class="spread">
            <span class="metric-label">Air quality</span>
            <span class="readout">
              {{ derived?.airQuality }}
              <span v-if="ambient.pm25 != null" class="band">PM2.5 {{ Math.round(ambient.pm25) }}</span>
            </span>
          </div>
        </template>
      </section>

      <!-- Privacy + notifications -->
      <section class="card">
        <p class="card-title">This device</p>
        <div class="row" style="gap: 7px">
          <span class="pill"><AppIcon name="shield" :size="13" /> Vitals stay on your network</span>
          <span class="pill">
            <AppIcon name="signal" :size="13" :style="{ color: connected ? 'var(--ok)' : 'var(--text-faint)' }" />
            {{ connected ? 'Socket live' : 'Reconnecting' }}
          </span>
        </div>
        <div v-if="notifState !== 'granted'" style="margin-top: 13px">
          <button class="btn" :disabled="notifState === 'denied'" @click="askNotifications">
            <AppIcon name="bell" :size="14" />
            {{ notifState === 'denied' ? 'Notifications blocked in browser' : 'Enable alert notifications' }}
          </button>
        </div>
        <p v-else class="note" style="margin-top: 12px">
          Notifications on — critical alerts appear even when this tab is in the background.
        </p>
      </section>

      <p v-if="activeCritical" class="faint" style="text-align: center; padding-bottom: 4px">
        An unacknowledged critical alert is open. See the Alerts tab.
      </p>
    </template>
  </div>
</template>
