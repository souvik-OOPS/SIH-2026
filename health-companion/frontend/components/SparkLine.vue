<script setup lang="ts">
/**
 * Tiny inline SVG sparkline. Deliberately not Chart.js — this redraws on every
 * incoming sample on the live page, and an SVG path is far cheaper than a
 * canvas chart instance.
 */
const props = withDefaults(defineProps<{
  points: (number | null)[]
  color?: string
  height?: number
  fill?: boolean
}>(), {
  color: '#38bdf8',
  height: 44,
  fill: true,
})

const W = 300

const geometry = computed(() => {
  const vals = props.points.filter((p): p is number => typeof p === 'number' && Number.isFinite(p))
  if (vals.length < 2) return null

  const min = Math.min(...vals)
  const max = Math.max(...vals)
  // A flat line should sit mid-height rather than divide by zero.
  const span = max - min || 1
  const h = props.height
  const pad = 3

  const coords = vals.map((v, i) => {
    const x = (i / (vals.length - 1)) * W
    const y = pad + (1 - (v - min) / span) * (h - pad * 2)
    return [x, y] as const
  })

  const line = coords.map(([x, y], i) => `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`).join(' ')
  const area = `${line} L${W},${h} L0,${h} Z`

  return { line, area, min, max, last: coords[coords.length - 1] }
})
</script>

<template>
  <svg v-if="geometry" :viewBox="`0 0 ${W} ${height}`" :height="height" width="100%" preserveAspectRatio="none" role="img" aria-label="Recent trend">
    <path v-if="fill" :d="geometry.area" :fill="color" opacity="0.13" />
    <path :d="geometry.line" :stroke="color" stroke-width="2" fill="none" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke" />
    <circle :cx="geometry.last[0]" :cy="geometry.last[1]" r="3" :fill="color" />
  </svg>
  <div v-else class="faint" :style="{ height: `${height}px`, display: 'flex', alignItems: 'center' }">
    Collecting samples…
  </div>
</template>
