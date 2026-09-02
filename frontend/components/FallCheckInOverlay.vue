<script setup lang="ts">
/**
 * "Are you okay?" after a probable fall.
 *
 * Deliberately blocking and full-screen. Everything else on this dashboard is
 * information; this is the one thing that asks the wearer to act, and burying
 * it in a corner would defeat the point. It stays up until answered or until
 * the window closes.
 *
 * The countdown is advisory — the server decides when the window has closed.
 * If this tab were asleep, backgrounded, or the phone locked, the escalation
 * still happens server-side, so the number here can never be the thing that
 * decides whether help is called.
 */
const { checkIn, respondOk, clearCheckIn, apiBase, deviceId } = useHealth()

const responding = ref(false)
const refused = ref(false)
const packet = ref<Record<string, unknown> | null>(null)
const loadingPacket = ref(false)

const visible = computed(
  () => checkIn.value.state === 'awaiting' || checkIn.value.state === 'escalated',
)
const escalated = computed(() => checkIn.value.state === 'escalated')

const seconds = computed(() => Math.max(0, checkIn.value.remainingSeconds ?? 0))
const total = computed(() => checkIn.value.windowSeconds ?? 30)
const progress = computed(() =>
  total.value === 0 ? 0 : Math.max(0, Math.min(1, seconds.value / total.value)),
)

async function onOk() {
  responding.value = true
  refused.value = false
  const accepted = await respondOk()
  // A refusal means the window closed first. The overlay switches to the
  // escalated state rather than pretending the press landed.
  if (!accepted) refused.value = true
  responding.value = false
}

async function showPacket() {
  loadingPacket.value = true
  try {
    const res = await $fetch<{ packet: Record<string, unknown> }>(
      `${apiBase}/api/safety/${deviceId}/emergency-packet`,
    )
    packet.value = res.packet
  } catch {
    packet.value = null
  }
  loadingPacket.value = false
}
</script>

<template>
  <div v-if="visible" class="scrim" role="alertdialog" aria-modal="true">
    <div class="panel" :class="{ 'panel--escalated': escalated }">
      <template v-if="!escalated">
        <p class="eyebrow">Possible fall detected</p>
        <h2 class="ask">Are you okay?</h2>

        <div class="count" :class="{ 'count--urgent': seconds <= 5 }">
          {{ seconds }}
          <span class="count__unit">s</span>
        </div>
        <div class="bar">
          <div class="bar__fill" :style="{ width: `${progress * 100}%` }" />
        </div>

        <p class="sub">
          If you do not respond, this will escalate to your emergency contacts.
        </p>

        <button class="ok" :disabled="responding" @click="onOk">
          {{ responding ? 'Sending…' : "I'M OK" }}
        </button>

        <p v-if="checkIn.fall?.reason" class="why">{{ checkIn.fall.reason }}</p>
      </template>

      <template v-else>
        <p class="eyebrow eyebrow--crit">No response</p>
        <h2 class="ask">Escalated</h2>
        <p class="sub">
          The check-in window closed without a response, so this was escalated
          locally and an emergency summary was prepared.
        </p>
        <p v-if="refused" class="sub sub--warn">
          Your response arrived after the window had already closed, so it was
          not accepted. Contact your emergency contacts directly if you are okay.
        </p>

        <div class="row">
          <button class="ghost" :disabled="loadingPacket" @click="showPacket">
            {{ loadingPacket ? 'Loading…' : 'View emergency summary' }}
          </button>
          <button class="ghost" @click="clearCheckIn">Dismiss</button>
        </div>

        <pre v-if="packet" class="packet">{{ JSON.stringify(packet, null, 2) }}</pre>
      </template>
    </div>
  </div>
</template>

<style scoped>
.scrim {
  position: fixed;
  inset: 0;
  z-index: 900;
  display: grid;
  place-items: center;
  padding: 20px;
  background: rgba(4, 6, 10, 0.88);
  backdrop-filter: blur(3px);
}

.panel {
  width: 100%;
  max-width: 380px;
  max-height: 88vh;
  overflow-y: auto;
  padding: 26px 22px;
  text-align: center;
  border: 1px solid var(--crit);
  border-radius: var(--radius);
  background: var(--surface);
}
.panel--escalated { border-color: var(--warn); }

.eyebrow {
  margin: 0 0 6px;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--crit);
}
.eyebrow--crit { color: var(--warn); }

.ask { margin: 0 0 18px; font-size: 26px; font-weight: 700; color: var(--text); }

.count {
  font-family: var(--mono);
  font-size: 62px;
  font-weight: 600;
  line-height: 1;
  color: var(--text);
  font-variant-numeric: tabular-nums;
}
.count--urgent { color: var(--crit); }
.count__unit { font-size: 22px; color: var(--text-dim); }

.bar {
  height: 5px;
  margin: 16px 0 18px;
  border-radius: 30px;
  background: var(--surface-3);
  overflow: hidden;
}
.bar__fill {
  height: 100%;
  background: var(--crit);
  transition: width 0.95s linear;
}

.sub { margin: 0 0 18px; font-size: 13.5px; line-height: 1.5; color: var(--text-dim); }
.sub--warn { color: var(--warn); }

.ok {
  width: 100%;
  padding: 18px;
  font-family: inherit;
  font-size: 19px;
  font-weight: 700;
  letter-spacing: 0.06em;
  color: #06231a;
  background: var(--ok);
  border: none;
  border-radius: var(--radius-sm);
  cursor: pointer;
}
.ok:disabled { opacity: 0.6; cursor: default; }

.why {
  margin: 16px 0 0;
  font-size: 11.5px;
  line-height: 1.45;
  color: var(--text-faint);
}

.row { display: flex; gap: 10px; }
.ghost {
  flex: 1;
  padding: 12px;
  font-family: inherit;
  font-size: 13px;
  color: var(--text);
  background: transparent;
  border: 1px solid var(--line-strong);
  border-radius: var(--radius-sm);
  cursor: pointer;
}

.packet {
  margin: 16px 0 0;
  padding: 12px;
  max-height: 260px;
  overflow: auto;
  text-align: left;
  font-family: var(--mono);
  font-size: 10.5px;
  line-height: 1.5;
  color: var(--text-dim);
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: var(--radius-xs);
}
</style>
