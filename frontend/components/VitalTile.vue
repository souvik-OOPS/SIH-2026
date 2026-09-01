<script setup lang="ts">
const props = withDefaults(defineProps<{
  label: string
  value: number | string | null | undefined
  unit?: string
  /** Name from AppIcon's set, not an emoji. */
  icon?: string
  foot?: string
  status?: 'ok' | 'warn' | 'crit'
  /** Greys the tile out when the underlying signal is unreliable. */
  stale?: boolean
  /** Beats-per-minute; when set, the icon pulses in time with it. */
  beat?: number | null
}>(), {
  status: 'ok',
  stale: false,
})

const display = computed(() => {
  if (props.value === null || props.value === undefined || props.value === '') return '––'
  return props.value
})

// A word ("active") needs a smaller size than a three-digit reading.
const isText = computed(() => typeof props.value === 'string' && props.value !== '')

// Cap the animation so a bad PPG sample can't make the heart strobe.
const beatDuration = computed(() => {
  if (!props.beat || props.beat < 30) return null
  return `${(60 / Math.min(props.beat, 200)).toFixed(2)}s`
})
</script>

<template>
  <div class="vital" :class="{ 'is-warn': status === 'warn', 'is-crit': status === 'crit', 'is-stale': stale }">
    <span class="edge" />
    <div class="label">
      <AppIcon
        v-if="icon"
        :name="icon"
        :size="14"
        :class="[icon === 'heart' ? 'icon-heart' : '', beatDuration ? 'pulse' : '']"
        :style="beatDuration ? { '--beat': beatDuration } : undefined"
      />
      <span>{{ label }}</span>
    </div>
    <div class="value">
      <span class="num" :class="{ 'is-text': isText }">{{ display }}</span>
      <span v-if="unit && display !== '––'" class="unit">{{ unit }}</span>
    </div>
    <div class="foot">{{ foot }}</div>
  </div>
</template>
