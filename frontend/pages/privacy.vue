<script setup lang="ts">
/**
 * Privacy and data controls.
 *
 * Shows what is held, why, and where — then lets the wearer clear the learned
 * baseline or delete their health data outright. The summary deliberately
 * shows counts and time bounds rather than the readings themselves: a screen
 * about privacy should not become one more place the data is displayed.
 */
const { apiBase, deviceId } = useHealth()

useHead({ title: 'Privacy — Health Companion' })

interface PrivacyPayload {
  stored: {
    storage: string
    readings: number
    alerts: number
    oldestReading: string | null
    newestReading: string | null
    deviceRecord: string[]
  }
  baseline: { restingHr: number | null; samples: number; ready: boolean; note: string }
  consent: Record<string, string>
}

const data = ref<PrivacyPayload | null>(null)
const loading = ref(true)
const busy = ref('')
const message = ref('')
const confirming = ref<'none' | 'data' | 'profile'>('none')

async function load() {
  loading.value = true
  try {
    data.value = await $fetch<PrivacyPayload>(`${apiBase}/api/safety/${deviceId}/privacy`)
  } catch {
    data.value = null
  }
  loading.value = false
}

onMounted(load)

async function clearBaseline() {
  busy.value = 'baseline'
  try {
    await $fetch(`${apiBase}/api/safety/${deviceId}/clear-baseline`, { method: 'POST' })
    message.value = 'Learned baseline cleared. It will start learning again from your next readings.'
  } catch {
    message.value = 'Could not clear the baseline. Is the server running?'
  }
  busy.value = ''
  await load()
}

async function deleteData(includeProfile: boolean) {
  busy.value = 'delete'
  try {
    const res = await $fetch<{ deleted: { readings: number; alerts: number } }>(
      `${apiBase}/api/safety/${deviceId}/data`,
      { method: 'DELETE', query: { confirm: 'true', includeProfile: String(includeProfile) } },
    )
    message.value = `Deleted ${res.deleted.readings} readings and ${res.deleted.alerts} alerts.`
      + (includeProfile ? ' The device registration was also removed.' : '')
  } catch {
    message.value = 'Could not delete the data. Is the server running?'
  }
  busy.value = ''
  confirming.value = 'none'
  await load()
}

const CONSENT_LABELS: Record<string, string> = {
  whatIsCollected: 'What is collected',
  whyItIsCollected: 'Purpose of collection',
  whereItIsStored: 'Storage location',
  whatLeavesTheDevice: 'What leaves your network',
  retention: 'Retention policy',
  yourControls: 'Your controls',
}
</script>

<template>
  <div>
    <header class="topbar">
      <div>
        <h1>Privacy &amp; Data</h1>
        <p class="sub">Local telemetry &middot; Zero third-party cloud upload</p>
      </div>
      <button class="btn small ghost" :disabled="loading" @click="load">
        <AppIcon name="refresh" :size="13" /> Refresh
      </button>
    </header>

    <div v-if="loading" class="card">
      <p class="empty" style="padding: 24px">Reading local privacy manifest…</p>
    </div>

    <template v-else-if="data">
      <div v-if="message" class="banner info" style="margin-bottom: 14px">
        <AppIcon class="icon" name="check" :size="16" />
        <div style="flex: 1">
          <div class="msg">{{ message }}</div>
        </div>
      </div>

      <div class="dashboard-grid">
        <!-- Left Column: Storage Metrics & Integrity -->
        <div class="dashboard-col" style="display: flex; flex-direction: column; gap: 12px">
          <section class="card" style="margin-bottom: 0">
            <p class="card-title">Stored on this system</p>
            <div class="grid-2" style="margin-bottom: 12px">
              <div class="vital" style="padding: 12px">
                <span class="stat-key">Telemetry Readings</span>
                <div class="stat-val" style="margin-top: 6px">{{ data.stored.readings }}</div>
                <div class="stat-sub">Samples cached locally</div>
              </div>
              <div class="vital" style="padding: 12px">
                <span class="stat-key">Alert Incidents</span>
                <div class="stat-val" style="margin-top: 6px">{{ data.stored.alerts }}</div>
                <div class="stat-sub">Incident logs</div>
              </div>
              <div class="vital" style="padding: 12px">
                <span class="stat-key">Storage Driver</span>
                <div class="stat-val" style="margin-top: 6px; font-size: 15px">{{ data.stored.storage }}</div>
                <div class="stat-sub">Local-first engine</div>
              </div>
              <div class="vital" style="padding: 12px">
                <span class="stat-key">Learned Resting HR</span>
                <div class="stat-val" style="margin-top: 6px">
                  {{ data.baseline.restingHr != null ? `${data.baseline.restingHr} bpm` : 'Learning…' }}
                </div>
                <div class="stat-sub">Personal baseline</div>
              </div>
            </div>

            <p class="note" style="margin-top: 4px">{{ data.baseline.note }}</p>
            <div v-if="data.stored.deviceRecord.length" class="row" style="margin-top: 10px; gap: 6px">
              <span class="faint">Profile keys:</span>
              <span v-for="f in data.stored.deviceRecord" :key="f" class="pill mono" style="font-size: 10px">
                {{ f }}
              </span>
            </div>
          </section>

          <!-- Controls Section -->
          <section class="card" style="margin-bottom: 0">
            <p class="card-title">Your Local Data Controls</p>

            <div class="spread" style="padding: 10px 0; border-bottom: 1px solid var(--line)">
              <div style="max-width: 68%">
                <div style="font-size: 13.5px; font-weight: 600; color: var(--text)">Clear learned baseline</div>
                <p class="faint" style="margin: 3px 0 0; line-height: 1.4">
                  Forgets your resting heart rate EWMA. Anomaly detection falls back to general age profile.
                </p>
              </div>
              <button class="btn small" :disabled="busy === 'baseline'" @click="clearBaseline">
                {{ busy === 'baseline' ? 'Clearing…' : 'Reset Baseline' }}
              </button>
            </div>

            <div class="spread" style="padding: 12px 0; border-bottom: 1px solid var(--line)">
              <div style="max-width: 68%">
                <div style="font-size: 13.5px; font-weight: 600; color: var(--text)">Purge health telemetry</div>
                <p class="faint" style="margin: 3px 0 0; line-height: 1.4">
                  Deletes all historical samples and alerts. Device registration and emergency contacts are preserved.
                </p>
              </div>
              <button
                v-if="confirming !== 'data'"
                class="btn small ghost-danger"
                @click="confirming = 'data'"
              >
                Purge Data
              </button>
              <div v-else class="row" style="gap: 6px">
                <button class="btn small ghost" @click="confirming = 'none'">Cancel</button>
                <button class="btn small danger" :disabled="busy === 'delete'" @click="deleteData(false)">
                  {{ busy === 'delete' ? 'Purging…' : 'Confirm' }}
                </button>
              </div>
            </div>

            <div class="spread" style="padding: 12px 0">
              <div style="max-width: 68%">
                <div style="font-size: 13.5px; font-weight: 600; color: var(--text)">Factory Reset Device</div>
                <p class="faint" style="margin: 3px 0 0; line-height: 1.4">
                  Removes all data, device records, and emergency contact mappings.
                </p>
              </div>
              <button
                v-if="confirming !== 'profile'"
                class="btn small ghost-danger"
                @click="confirming = 'profile'"
              >
                Delete All
              </button>
              <div v-else class="row" style="gap: 6px">
                <button class="btn small ghost" @click="confirming = 'none'">Cancel</button>
                <button class="btn small danger" :disabled="busy === 'delete'" @click="deleteData(true)">
                  {{ busy === 'delete' ? 'Deleting…' : 'Confirm Reset' }}
                </button>
              </div>
            </div>

            <p class="faint" style="margin: 10px 0 0; color: var(--warn); font-size: 11px">
              Data purging is permanent and cannot be reversed.
            </p>
          </section>
        </div>

        <!-- Right Column: Compliance & Architecture explanations -->
        <div class="dashboard-col" style="display: flex; flex-direction: column; gap: 12px">
          <section class="card" style="margin-bottom: 0">
            <p class="card-title">Privacy Architecture &amp; Consent</p>
            <div style="display: flex; flex-direction: column; gap: 14px">
              <div v-for="(value, key) in data.consent" :key="key" style="border-bottom: 1px solid var(--line); padding-bottom: 12px">
                <span class="stat-key" style="color: var(--accent)">{{ CONSENT_LABELS[key] ?? key }}</span>
                <p style="margin: 5px 0 0; font-size: 13px; line-height: 1.5; color: var(--text-dim)">
                  {{ value }}
                </p>
              </div>
            </div>

            <div class="row" style="margin-top: 14px; gap: 8px">
              <span class="pill"><AppIcon name="shield" :size="13" /> Zero Cloud Dependency</span>
              <span class="pill mono"><AppIcon name="check" :size="13" /> On-Device Ingest</span>
            </div>
          </section>
        </div>
      </div>
    </template>

    <div v-else class="card">
      <p class="empty">
        Could not reach the backend service.<br >
        Please ensure the local server is running on port 4000.
      </p>
    </div>
  </div>
</template>
