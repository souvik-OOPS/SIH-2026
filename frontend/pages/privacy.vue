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
  whyItIsCollected: 'Why',
  whereItIsStored: 'Where it is stored',
  whatLeavesTheDevice: 'What leaves this device',
  retention: 'How long it is kept',
  yourControls: 'Your controls',
}
</script>

<template>
  <main class="page">
    <header class="head">
      <h1>Privacy &amp; data</h1>
      <p class="muted">Everything below is held locally. Nothing is uploaded automatically.</p>
    </header>

    <p v-if="loading" class="muted">Loading…</p>

    <template v-else-if="data">
      <p v-if="message" class="notice">{{ message }}</p>

      <!-- What is stored -->
      <section class="card">
        <h2 class="card-title">Stored on this system</h2>
        <dl class="grid">
          <div><dt>Readings</dt><dd>{{ data.stored.readings }}</dd></div>
          <div><dt>Alerts</dt><dd>{{ data.stored.alerts }}</dd></div>
          <div><dt>Storage</dt><dd>{{ data.stored.storage }}</dd></div>
          <div>
            <dt>Learned baseline</dt>
            <dd>{{ data.baseline.restingHr != null ? `${data.baseline.restingHr} bpm` : 'none yet' }}</dd>
          </div>
        </dl>
        <p class="fine">{{ data.baseline.note }}</p>
        <p v-if="data.stored.deviceRecord.length" class="fine">
          Profile fields held: {{ data.stored.deviceRecord.join(', ') }}
        </p>
      </section>

      <!-- Why -->
      <section class="card">
        <h2 class="card-title">What this means</h2>
        <dl class="stack">
          <div v-for="(value, key) in data.consent" :key="key">
            <dt>{{ CONSENT_LABELS[key] ?? key }}</dt>
            <dd>{{ value }}</dd>
          </div>
        </dl>
      </section>

      <!-- Controls -->
      <section class="card">
        <h2 class="card-title">Your controls</h2>

        <div class="action">
          <div>
            <p class="action__name">Clear learned baseline</p>
            <p class="fine">
              Forgets your resting heart rate. Alerts fall back to the
              age and profile thresholds until it relearns.
            </p>
          </div>
          <button class="ghost" :disabled="busy === 'baseline'" @click="clearBaseline">
            {{ busy === 'baseline' ? 'Clearing…' : 'Clear' }}
          </button>
        </div>

        <div class="action">
          <div>
            <p class="action__name">Delete health data</p>
            <p class="fine">
              Removes every stored reading and alert, and the learned baseline.
              Your device registration and emergency contacts are kept.
            </p>
          </div>
          <button
            v-if="confirming !== 'data'"
            class="ghost ghost--danger"
            @click="confirming = 'data'"
          >
            Delete
          </button>
          <div v-else class="confirm">
            <button class="ghost" @click="confirming = 'none'">Cancel</button>
            <button class="danger" :disabled="busy === 'delete'" @click="deleteData(false)">
              {{ busy === 'delete' ? 'Deleting…' : 'Confirm' }}
            </button>
          </div>
        </div>

        <div class="action">
          <div>
            <p class="action__name">Delete everything</p>
            <p class="fine">
              Also removes the device registration, emergency contacts and
              location. You would need to register the band again.
            </p>
          </div>
          <button
            v-if="confirming !== 'profile'"
            class="ghost ghost--danger"
            @click="confirming = 'profile'"
          >
            Delete all
          </button>
          <div v-else class="confirm">
            <button class="ghost" @click="confirming = 'none'">Cancel</button>
            <button class="danger" :disabled="busy === 'delete'" @click="deleteData(true)">
              {{ busy === 'delete' ? 'Deleting…' : 'Confirm' }}
            </button>
          </div>
        </div>

        <p class="fine fine--warn">Deleting cannot be undone.</p>
      </section>
    </template>

    <p v-else class="muted">
      Could not reach the server. Data controls need the backend running.
    </p>
  </main>
</template>

<style scoped>
.page { padding: 20px 16px 90px; max-width: 620px; margin: 0 auto; }
.head { margin-bottom: 18px; }
.head h1 { margin: 0 0 4px; font-size: 22px; font-weight: 700; }
.muted { color: var(--text-dim); font-size: 13px; margin: 0; }

.notice {
  margin: 0 0 14px;
  padding: 11px 13px;
  font-size: 13px;
  color: var(--ok);
  background: var(--ok-dim);
  border: 1px solid var(--ok);
  border-radius: var(--radius-sm);
}

.card {
  margin-bottom: 14px;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--surface);
}
.card-title {
  margin: 0 0 12px;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.07em;
  text-transform: uppercase;
  color: var(--text-dim);
}

.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin: 0 0 10px; }
.grid dt, .stack dt { font-size: 11px; color: var(--text-faint); margin-bottom: 2px; }
.grid dd { margin: 0; font-family: var(--mono); font-size: 18px; color: var(--text); }

.stack { margin: 0; display: grid; gap: 12px; }
.stack dd { margin: 0; font-size: 13px; line-height: 1.5; color: var(--text-dim); }

.fine { margin: 6px 0 0; font-size: 11.5px; line-height: 1.45; color: var(--text-faint); }
.fine--warn { color: var(--warn); margin-top: 14px; }

.action {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 14px;
  padding: 13px 0;
  border-top: 1px solid var(--line);
}
.action:first-of-type { border-top: none; padding-top: 0; }
.action__name { margin: 0; font-size: 14px; font-weight: 600; color: var(--text); }

.confirm { display: flex; gap: 7px; flex: 0 0 auto; }

.ghost, .danger {
  flex: 0 0 auto;
  padding: 9px 15px;
  font-family: inherit;
  font-size: 13px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  white-space: nowrap;
}
.ghost {
  color: var(--text);
  background: transparent;
  border: 1px solid var(--line-strong);
}
.ghost--danger { color: var(--crit); border-color: var(--crit); }
.danger {
  color: #fff;
  background: var(--crit);
  border: 1px solid var(--crit);
}
.ghost:disabled, .danger:disabled { opacity: 0.6; cursor: default; }
</style>
