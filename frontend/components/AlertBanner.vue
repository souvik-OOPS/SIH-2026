<script setup lang="ts">
import type { Alert } from '~/composables/useHealth'

defineProps<{ alert: Alert }>()
const emit = defineEmits<{ (e: 'ack', id: string): void }>()
</script>

<template>
  <div class="banner" :class="alert.severity" role="alert">
    <AppIcon class="icon" :name="SEVERITY_ICON[alert.severity]" :size="19" />
    <div style="flex: 1; min-width: 0">
      <div class="msg">{{ alert.message }}</div>
      <div v-if="alert.detail" class="detail">{{ alert.detail }}</div>
      <div class="row" style="margin-top: 10px; gap: 7px">
        <span class="faint mono">{{ clockTime(alert.timestamp) }}</span>
        <span v-if="alert.smsSent" class="faint row" style="gap: 4px">
          <AppIcon name="message" :size="12" /> Sent to emergency contact
        </span>
        <span v-else-if="alert.smsError" class="faint">SMS failed: {{ alert.smsError }}</span>
        <span v-else-if="alert.smsNote" class="faint">SMS held ({{ alert.smsNote }})</span>
      </div>
    </div>
    <button class="btn small ghost" @click="emit('ack', alert._id)">
      <AppIcon name="close" :size="13" />
    </button>
  </div>
</template>
