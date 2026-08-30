export default defineNuxtConfig({
  compatibilityDate: '2025-01-01',
  devtools: { enabled: false },

  modules: ['@vite-pwa/nuxt'],

  css: ['~/assets/css/main.css'],

  runtimeConfig: {
    public: {
      apiBase: process.env.NUXT_PUBLIC_API_BASE || 'http://localhost:4000',
      deviceId: process.env.NUXT_PUBLIC_DEVICE_ID || 'band-001',
    },
  },

  app: {
    head: {
      title: 'Health Companion',
      meta: [
        { name: 'viewport', content: 'width=device-width, initial-scale=1, viewport-fit=cover' },
        { name: 'theme-color', content: '#080b11' },
        { name: 'description', content: 'Privacy-preserving personal health monitoring with early warning for heat, air quality and falls.' },
        // Lets the PWA feel native when installed on iOS.
        { name: 'apple-mobile-web-app-capable', content: 'yes' },
        { name: 'apple-mobile-web-app-status-bar-style', content: 'black-translucent' },
      ],
      link: [
        { rel: 'apple-touch-icon', href: '/icons/icon-192.png' },
        { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
        { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' },
        {
          rel: 'stylesheet',
          href: 'https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600;700&display=swap',
        },
      ],
    },
  },

  pwa: {
    registerType: 'autoUpdate',
    manifest: {
      name: 'Personal Health Companion',
      short_name: 'Health',
      description: 'Real-time, privacy-preserving health monitoring with disaster-aware early warnings.',
      theme_color: '#080b11',
      background_color: '#080b11',
      display: 'standalone',
      orientation: 'portrait',
      start_url: '/',
      icons: [
        { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
        { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
        { src: '/icons/icon-512-maskable.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
      ],
    },
    workbox: {
      // NO navigateFallback. Nuxt renders real routes server-side, and a
      // fallback of '/' makes the service worker answer every navigation with
      // the home page's HTML — so a refresh or deep link on /history or
      // /alerts silently shows the live dashboard instead. Navigations are
      // handled by the NetworkFirst rule below, which keeps offline working
      // without breaking routing.
      //
      // Note: @vite-pwa/nuxt defaults this to '/', so it has to be nulled
      // explicitly — simply omitting the key leaves the default in place.
      navigateFallback: null as unknown as undefined,
      globPatterns: ['**/*.{js,css,html,png,svg,ico,woff2}'],
      runtimeCaching: [
        {
          // Webfonts are cross-origin, so globPatterns cannot precache them.
          // Without this the offline demo silently drops to the fallback face.
          urlPattern: /^https:\/\/fonts\.(googleapis|gstatic)\.com\/.*/i,
          handler: 'CacheFirst',
          options: {
            cacheName: 'google-fonts',
            expiration: { maxEntries: 20, maxAgeSeconds: 60 * 60 * 24 * 365 },
            cacheableResponse: { statuses: [0, 200] },
          },
        },
        {
          // Serve the real page when online; fall back to the last-seen copy
          // of that same route when the network is gone.
          urlPattern: ({ request }) => request.mode === 'navigate',
          handler: 'NetworkFirst',
          options: {
            cacheName: 'health-pages',
            networkTimeoutSeconds: 3,
            expiration: { maxEntries: 10, maxAgeSeconds: 60 * 60 * 24 },
            cacheableResponse: { statuses: [0, 200] },
          },
        },
        {
          // Cache the last known readings so the dashboard still renders
          // something useful when the network drops mid-demo.
          urlPattern: /\/api\/(history|alerts|devices)\//,
          handler: 'NetworkFirst',
          options: {
            cacheName: 'health-api',
            networkTimeoutSeconds: 3,
            expiration: { maxEntries: 40, maxAgeSeconds: 60 * 60 * 24 },
            cacheableResponse: { statuses: [0, 200] },
          },
        },
      ],
    },
    client: { installPrompt: true },
    devOptions: { enabled: true, suppressWarnings: true, type: 'module' },
  },
})
