<script setup lang="ts">
const { unacknowledged, start } = useHealth()

onMounted(() => start())

const TABS = [
  { to: '/', icon: 'pulse', label: 'Live' },
  { to: '/history', icon: 'chart', label: 'Trends' },
  { to: '/alerts', icon: 'bell', label: 'Alerts', badge: true },
]
</script>

<template>
  <div class="shell">
    <slot />

    <nav class="tabbar">
      <NuxtLink v-for="tab in TABS" :key="tab.to" :to="tab.to">
        <AppIcon :name="tab.icon" :size="19" />
        <span>{{ tab.label }}</span>
        <span v-if="tab.badge && unacknowledged" class="badge">{{ unacknowledged }}</span>
      </NuxtLink>
    </nav>
  </div>
</template>
