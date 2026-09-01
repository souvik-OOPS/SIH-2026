<script setup lang="ts">
/**
 * The icon set. One consistent style: 24px grid, 1.75 stroke, round caps and
 * joins, currentColor, no fills. Emoji were the previous placeholder — they
 * render differently on every OS, can't take a stroke weight, and read as
 * decoration rather than instrumentation, which is wrong for a medical device.
 */

withDefaults(defineProps<{ name: string; size?: number | string; stroke?: number }>(), {
  size: 18,
  stroke: 1.75,
})

// Each entry is the inner markup of a 24x24 viewBox.
const PATHS: Record<string, string> = {
  // — vitals —
  heart: '<path d="M12 20.3s-7.3-4.6-7.3-9.6a4.2 4.2 0 0 1 7.3-2.8 4.2 4.2 0 0 1 7.3 2.8c0 5-7.3 9.6-7.3 9.6Z"/>',
  droplet: '<path d="M12 3.4s5.4 5.9 5.4 9.4a5.4 5.4 0 1 1-10.8 0C6.6 9.3 12 3.4 12 3.4Z"/>',
  thermometer:
    '<path d="M14 14.6V5.2a2 2 0 1 0-4 0v9.4a4 4 0 1 0 4 0Z"/><path d="M12 16.2v-5"/>',
  // Movement as three ascending bars — an intensity readout, not a mascot.
  motion: '<path d="M5 15v4"/><path d="M10 11v8"/><path d="M15 7v12"/><path d="M20 13v6"/>',

  // — navigation —
  pulse: '<path d="M2 12h4l2.5-7 4.5 14 2.5-7H22"/>',
  chart: '<path d="M4 20V10"/><path d="M10 20V4"/><path d="M16 20v-6"/><path d="M21 20H3"/>',
  bell: '<path d="M18 9a6 6 0 1 0-12 0c0 5-2 6.5-2 6.5h16S18 14 18 9Z"/><path d="M13.7 19a2 2 0 0 1-3.4 0"/>',

  // — severity —
  info: '<circle cx="12" cy="12" r="8.6"/><path d="M12 11.4v4.8"/><path d="M12 8.2h.01"/>',
  warning:
    '<path d="M10.3 4.3 2.6 17.2A2 2 0 0 0 4.3 20.2h15.4a2 2 0 0 0 1.7-3L13.7 4.3a2 2 0 0 0-3.4 0Z"/><path d="M12 9.6v3.8"/><path d="M12 17h.01"/>',
  critical:
    '<path d="M8.6 3.4h6.8L20.6 8.6v6.8L15.4 20.6H8.6L3.4 15.4V8.6Z"/><path d="M12 8.4v4.2"/><path d="M12 16.2h.01"/>',

  // — status —
  shield: '<path d="M12 21.2s7-3.4 7-8.6V6.2L12 3.4 5 6.2v6.4c0 5.2 7 8.6 7 8.6Z"/><path d="M9.6 12.2l1.8 1.8 3.4-3.6"/>',
  signal: '<path d="M4.6 15.4a10.4 10.4 0 0 1 14.8 0"/><path d="M7.9 18.6a5.8 5.8 0 0 1 8.2 0"/><path d="M12 21.6h.01"/><path d="M1.4 12.1a15 15 0 0 1 21.2 0"/>',
  message: '<path d="M20.4 15.2a1.9 1.9 0 0 1-1.9 1.9H7.6L3.6 21V5.5a1.9 1.9 0 0 1 1.9-1.9h13a1.9 1.9 0 0 1 1.9 1.9Z"/>',
  check: '<path d="M4.8 12.6l4.6 4.6L19.2 7.4"/>',
  refresh: '<path d="M20.6 11.4a8.6 8.6 0 1 0-.8 4.4"/><path d="M20.6 4.9v6.5h-6.5"/>',
  close: '<path d="M17.6 6.4 6.4 17.6"/><path d="M6.4 6.4l11.2 11.2"/>',
}
</script>

<template>
  <svg
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    :stroke-width="stroke"
    stroke="currentColor"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
    focusable="false"
    class="app-icon"
    v-html="PATHS[name] ?? ''"
  />
</template>

<style scoped>
.app-icon {
  flex: none;
  display: block;
}
</style>
