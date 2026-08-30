<script setup lang="ts">
import {
  Chart,
  LineController,
  LineElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Tooltip,
  Legend,
  Filler,
} from 'chart.js'

Chart.register(LineController, LineElement, PointElement, LinearScale, CategoryScale, Tooltip, Legend, Filler)

export interface Series {
  label: string
  data: (number | null)[]
  color: string
  /** Plot against a second y-axis on the right. */
  axis?: 'y' | 'y1'
  fill?: boolean
  dashed?: boolean
}

const props = withDefaults(defineProps<{
  labels: string[]
  series: Series[]
  yLabel?: string
  y1Label?: string
  ySuggestedMin?: number
  ySuggestedMax?: number
}>(), {})

const canvas = ref<HTMLCanvasElement | null>(null)
let chart: Chart | null = null

const GRID = 'rgba(28, 36, 50, 0.9)'
const TICK = '#616e83'

function buildConfig() {
  const usesY1 = props.series.some((s) => s.axis === 'y1')

  return {
    type: 'line' as const,
    data: {
      labels: props.labels,
      datasets: props.series.map((s) => ({
        label: s.label,
        data: s.data,
        borderColor: s.color,
        backgroundColor: s.fill ? `${s.color}22` : s.color,
        borderWidth: 2,
        borderDash: s.dashed ? [4, 4] : undefined,
        pointRadius: 0,
        pointHoverRadius: 4,
        tension: 0.32,
        fill: s.fill ?? false,
        yAxisID: s.axis ?? 'y',
        spanGaps: true,
      })),
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 250 },
      interaction: { mode: 'index' as const, intersect: false },
      plugins: {
        legend: {
          display: true,
          labels: {
            color: TICK,
            boxWidth: 10,
            boxHeight: 10,
            usePointStyle: true,
            pointStyle: 'circle',
            font: { family: "'IBM Plex Sans', sans-serif", size: 11 },
          },
        },
        tooltip: {
          backgroundColor: '#0e131c',
          borderColor: GRID,
          borderWidth: 1,
          titleColor: '#e7ebf2',
          bodyColor: '#93a0b4',
          titleFont: { family: "'IBM Plex Mono', monospace", size: 11 },
          bodyFont: { family: "'IBM Plex Mono', monospace", size: 11 },
          padding: 10,
          displayColors: true,
          usePointStyle: true,
        },
      },
      scales: {
        x: {
          grid: { color: GRID, drawTicks: false },
          border: { display: false },
          ticks: { color: TICK, maxTicksLimit: 6, font: { family: "'IBM Plex Mono', monospace", size: 10 }, maxRotation: 0 },
        },
        y: {
          position: 'left' as const,
          grid: { color: GRID, drawTicks: false },
          border: { display: false },
          ticks: { color: TICK, font: { family: "'IBM Plex Mono', monospace", size: 10 }, maxTicksLimit: 6 },
          title: props.yLabel ? { display: true, text: props.yLabel, color: TICK, font: { family: "'IBM Plex Sans', sans-serif", size: 10 } } : undefined,
          suggestedMin: props.ySuggestedMin,
          suggestedMax: props.ySuggestedMax,
        },
        ...(usesY1
          ? {
              y1: {
                position: 'right' as const,
                grid: { drawOnChartArea: false },
                border: { display: false },
                ticks: { color: TICK, font: { family: "'IBM Plex Mono', monospace", size: 10 }, maxTicksLimit: 6 },
                title: props.y1Label ? { display: true, text: props.y1Label, color: TICK, font: { family: "'IBM Plex Sans', sans-serif", size: 10 } } : undefined,
              },
            }
          : {}),
      },
    },
  }
}

onMounted(() => {
  if (!canvas.value) return
  chart = new Chart(canvas.value, buildConfig())
})

// Mutate the existing chart instead of recreating it — recreating on every
// tick makes the live view flicker.
watch(
  () => [props.labels, props.series] as const,
  () => {
    if (!chart) return
    chart.data.labels = props.labels
    const next = buildConfig()
    chart.data.datasets = next.data.datasets
    chart.options = next.options as never
    chart.update('none')
  },
  { deep: true }
)

onBeforeUnmount(() => {
  chart?.destroy()
  chart = null
})
</script>

<template>
  <div class="chart-wrap">
    <canvas ref="canvas" />
  </div>
</template>
