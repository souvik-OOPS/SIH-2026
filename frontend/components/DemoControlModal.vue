<script setup lang="ts">
const props = defineProps<{
  show: boolean
}>()

const emit = defineEmits<{
  (e: 'close'): void
}>()

const { apiBase, deviceId } = useHealth()

const activeScenario = ref<string | null>(null)
const loading = ref(false)
const statusMessage = ref<string | null>(null)

interface ScenarioPreset {
  id: string
  name: string
  icon: string
  tag: string
  severity: 'crit' | 'warn' | 'accent' | 'ok'
  desc: string
  params: { tempC: number; humidity: number; aqi: number; pm25: number }
}

const PRESETS: ScenarioPreset[] = [
  {
    id: 'heatwave',
    name: 'Heatwave Emergency',
    icon: 'thermometer',
    tag: 'Extreme Heat',
    severity: 'crit',
    desc: '44°C at 62% RH. Dangerously high heat index with physiological strain.',
    params: { tempC: 44, humidity: 62, aqi: 3, pm25: 74 },
  },
  {
    id: 'pollution',
    name: 'Severe Smog / AQI Spike',
    icon: 'shield',
    tag: 'Hazardous Air',
    severity: 'warn',
    desc: 'AQI 5 (Hazardous) with PM2.5 168 µg/m³. Tests air-quality early warnings.',
    params: { tempC: 29, humidity: 55, aqi: 5, pm25: 168 },
  },
  {
    id: 'flood',
    name: 'Post-Flood High Humidity',
    icon: 'droplet',
    tag: 'Tropical Humidity',
    severity: 'accent',
    desc: '31°C at 94% RH. Tests apparent temperature escalation under saturated air.',
    params: { tempC: 31, humidity: 94, aqi: 2, pm25: 28 },
  },
  {
    id: 'normal',
    name: 'Normal Environment',
    icon: 'check',
    tag: 'Nominal',
    severity: 'ok',
    desc: '29°C at 55% RH, AQI 2. Baseline environmental telemetry.',
    params: { tempC: 29, humidity: 55, aqi: 2, pm25: 32 },
  },
]

async function triggerScenario(presetId: string) {
  loading.value = true
  statusMessage.value = null
  try {
    const res = await $fetch<{ ok: boolean; override: unknown }>(`${apiBase}/api/demo/env`, {
      method: 'POST',
      body: { preset: presetId },
    })
    if (res.ok) {
      activeScenario.value = presetId
      statusMessage.value = `Applied ${presetId} scenario override.`
    }
  } catch {
    statusMessage.value = 'Failed to connect to backend demo endpoint.'
  } finally {
    loading.value = false
  }
}

async function clearOverride() {
  loading.value = true
  statusMessage.value = null
  try {
    await $fetch(`${apiBase}/api/demo/env`, { method: 'DELETE' })
    activeScenario.value = null
    statusMessage.value = 'Cleared overrides. Reverted to hardware/live feeds.'
  } catch {
    statusMessage.value = 'Failed to clear override.'
  } finally {
    loading.value = false
  }
}

async function resetState() {
  loading.value = true
  statusMessage.value = null
  try {
    await $fetch(`${apiBase}/api/demo/reset/${deviceId}`, { method: 'POST' })
    statusMessage.value = 'Detector cooldowns and EWMA baselines reset.'
  } catch {
    statusMessage.value = 'Failed to reset device state.'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div v-if="show" class="modal-scrim" @click.self="emit('close')">
    <div class="modal-dialog">
      <div class="spread" style="margin-bottom: 16px">
        <div>
          <h2 style="margin: 0; font-size: 17px; font-weight: 600; display: flex; align-items: center; gap: 8px">
            <AppIcon name="signal" :size="16" style="color: var(--accent)" />
            Evaluator Demo Controller
          </h2>
          <p class="faint" style="margin: 4px 0 0">
            Inject telemetry conditions live to test SIH early warning rules.
          </p>
        </div>
        <button class="btn small ghost" @click="emit('close')">
          <AppIcon name="close" :size="14" />
        </button>
      </div>

      <div v-if="statusMessage" class="banner info" style="margin-bottom: 14px; padding: 10px 12px">
        <AppIcon class="icon" name="check" :size="16" />
        <span class="faint" style="color: var(--text); font-size: 12px">{{ statusMessage }}</span>
      </div>

      <p class="card-title" style="margin-bottom: 10px">Environmental Scenarios</p>
      <div style="display: flex; flex-direction: column; gap: 8px; margin-bottom: 18px">
        <div
          v-for="p in PRESETS"
          :key="p.id"
          class="card"
          style="margin-bottom: 0; padding: 12px 14px; cursor: pointer; transition: border-color 0.2s ease, background 0.2s ease"
          :style="{
            borderColor: activeScenario === p.id ? 'var(--accent)' : 'var(--line)',
            background: activeScenario === p.id ? 'var(--surface-2)' : 'var(--surface)',
          }"
          @click="triggerScenario(p.id)"
        >
          <div class="spread" style="margin-bottom: 4px">
            <span style="font-size: 13.5px; font-weight: 600; color: var(--text)">{{ p.name }}</span>
            <span
              class="pill mono"
              :style="{
                color: p.severity === 'crit' ? 'var(--crit)' : p.severity === 'warn' ? 'var(--warn)' : 'var(--accent)',
                borderColor: 'transparent',
                background: 'rgba(255,255,255,0.05)',
              }"
            >
              {{ p.tag }}
            </span>
          </div>
          <p class="faint" style="margin: 0; font-size: 11.5px; line-height: 1.4">{{ p.desc }}</p>
        </div>
      </div>

      <div class="rule" style="margin: 14px 0" />

      <p class="card-title" style="margin-bottom: 10px">Stage & Cooldown Controls</p>
      <div class="row" style="gap: 10px">
        <button class="btn small" :disabled="loading" @click="resetState">
          <AppIcon name="refresh" :size="13" /> Reset Alert Cooldowns
        </button>
        <button class="btn small ghost-danger" :disabled="loading" @click="clearOverride">
          Revert to Live Feed
        </button>
      </div>
    </div>
  </div>
</template>
