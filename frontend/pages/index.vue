<script setup lang="ts">
const {
  latest, trail, device, banner, connected, deviceOnline, now,
  disaster, loadDisasterContext,
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
const showDemo = ref(false)

// Disaster context is enrichment: fetched once on mount and refreshed slowly,
// never blocking the vitals view. A failure leaves the card in its explicit
// "unavailable" state rather than hiding it.
let disasterTimer: ReturnType<typeof setInterval> | null = null

onMounted(() => {
  loadDisasterContext()
  disasterTimer = setInterval(loadDisasterContext, 15 * 60 * 1000)

  if (typeof Notification !== 'undefined') {
    notifState.value = Notification.permission === 'granted' ? 'granted'
      : Notification.permission === 'denied' ? 'denied' : 'unknown'
  }
})

onUnmounted(() => {
  if (disasterTimer) clearInterval(disasterTimer)
  disasterTimer = null
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

const dhtAvailable = computed(() =>
  latest.value?.ambientTemp != null && latest.value?.humidity != null
)

const ambientFoot = computed(() =>
  latest.value?.humidity != null
    ? `Humidity ${latest.value.humidity.toFixed(0)}% RH`
    : 'Waiting for valid DHT data'
)

const humidityFoot = computed(() =>
  latest.value?.ambientTemp != null
    ? `Ambient ${latest.value.ambientTemp.toFixed(1)}°C`
    : 'Waiting for valid DHT data'
)
</script>

<template>
  <div>
    <header class="topbar">
      <div>
        <h1>{{ wearer }}</h1>
        <p class="sub">{{ profileLabel[device?.profile ?? 'general'] }} &middot; {{ lastSeenText }}</p>
      </div>
      <div class="row" style="gap: 8px">
        <button class="btn small demo-pill" @click="showDemo = true">
          <AppIcon name="signal" :size="12" /> Demo Mode
        </button>
        <span class="pill">
          <span class="dot" :class="deviceOnline ? 'live' : 'down'" />
          {{ deviceOnline ? 'Live' : connected ? 'No signal' : 'Offline' }}
        </span>
      </div>
    </header>

    <AlertBanner v-if="banner" :alert="banner" @ack="acknowledge" />

    <div v-if="!latest" class="card" style="text-align: center; padding: 42px 20px 32px">
      <div class="radar-scan">
        <AppIcon name="signal" :size="26" style="color: var(--accent)" />
      </div>
      <h2 style="font-size: 16px; font-weight: 600; margin: 0 0 6px">Awaiting Telemetry Stream</h2>
      <p class="muted" style="max-width: 400px; margin: 0 auto 18px; font-size: 13px; line-height: 1.55">
        Listening on WebSocket for ESP32 hardware packets or the local simulator feed.
      </p>
      <div class="row" style="justify-content: center; gap: 10px; margin-bottom: 18px">
        <span class="pill mono"><span class="dot live" /> Ingest Port 4000</span>
        <button class="btn small primary" @click="showDemo = true">
          <AppIcon name="signal" :size="12" /> Launch Evaluator Scenarios
        </button>
      </div>
      <div style="padding-top: 14px; border-top: 1px solid var(--line)">
        <span class="faint mono" style="font-size: 11px">Hardware simulator command: npm run simulate</span>
      </div>
    </div>

    <div v-else class="dashboard-grid">
      <!-- Left Column: Primary physiological telemetry -->
      <div class="dashboard-col" style="display: flex; flex-direction: column; gap: 10px">
        <div class="grid-2" style="margin-bottom: 0">
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

        <div class="grid-2" style="margin-bottom: 0">
          <VitalTile
            label="Ambient temp"
            icon="thermometer"
            :value="latest.ambientTemp"
            unit="°C"
            :foot="ambientFoot"
          />
          <VitalTile
            label="Humidity"
            icon="droplet"
            :value="latest.humidity"
            unit="%"
            :foot="humidityFoot"
          />
        </div>

        <div class="grid-2" style="margin-bottom: 0">
          <VitalTile
            :class="{ 'movement-tile': latest.bodyTemp == null }"
            label="Movement"
            icon="motion"
            :value="motionLabel"
            :foot="latest.accelMagnitude != null ? `${latest.accelMagnitude.toFixed(2)} g` : ''"
          />
          <VitalTile
            v-if="latest.bodyTemp != null"
            label="Body temp"
            icon="thermometer"
            :value="latest.bodyTemp"
            unit="°C"
            :status="latest.bodyTemp > 38 ? 'crit' : latest.bodyTemp > 37.5 ? 'warn' : 'ok'"
            foot="Core estimate"
          />
        </div>

        <!-- Heart-rate trace -->
        <section class="card" style="margin-bottom: 0">
          <div class="spread" style="margin-bottom: 12px">
            <p class="card-title" style="margin: 0">Heart rate &middot; last 60 samples</p>
            <span class="faint mono">{{ clockTime(latest.timestamp) }}</span>
          </div>
          <SparkLine :points="hrTrail" color="#ff4f63" :height="64" />
        </section>
      </div>

      <!-- Right Column: Environmental risk & intelligence context -->
      <div class="dashboard-col" style="display: flex; flex-direction: column; gap: 10px">
        <DisasterContextCard :context="disaster" />

        <!-- Environmental risk card -->
        <section class="card" style="margin-bottom: 0">
          <p class="card-title">Environmental Risk &amp; Strain</p>

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
          <p v-if="dhtAvailable" class="note">
            Apparent temperature from {{ latest.ambientTemp ?? '––' }}°C at {{ latest.humidity ?? '––' }}% RH
            ({{ envSourceLabel }}).
            <template v-if="derived?.heatIndexExtrapolated">Beyond the NWS chart's validated range.</template>
          </p>
          <p v-else class="note">
            No valid DHT sample reached the backend yet. Showing fallback weather telemetry.
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

        <!-- Device & Network status -->
        <section class="card" style="margin-bottom: 0">
          <p class="card-title">Device &amp; Telemetry Status</p>
          <div class="row" style="gap: 7px">
            <span class="pill"><AppIcon name="shield" :size="13" /> Edge processing</span>
            <span class="pill">
              <AppIcon name="signal" :size="13" :style="{ color: connected ? 'var(--ok)' : 'var(--text-faint)' }" />
              {{ connected ? 'WebSocket active' : 'Reconnecting' }}
            </span>
          </div>
          <div v-if="notifState !== 'granted'" style="margin-top: 13px">
            <button class="btn" :disabled="notifState === 'denied'" @click="askNotifications">
              <AppIcon name="bell" :size="14" />
              {{ notifState === 'denied' ? 'Notifications blocked' : 'Enable alert notifications' }}
            </button>
          </div>
          <p v-else class="note" style="margin-top: 12px">
            Notifications on — critical alerts notify even when this tab is backgrounded.
          </p>
        </section>
      </div>
    </div>

    <p v-if="activeCritical" class="faint" style="text-align: center; margin-top: 14px; padding-bottom: 4px">
      An unacknowledged critical alert is open. See the Alerts tab.
    </p>

    <DemoControlModal :show="showDemo" @close="showDemo = false" />
  </div>
</template>
