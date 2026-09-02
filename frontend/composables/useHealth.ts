import { io, type Socket } from 'socket.io-client'

export interface Reading {
  _id?: string
  deviceId: string
  heartRate: number | null
  spo2: number | null
  bodyTemp: number | null
  ambientTemp: number | null
  humidity: number | null
  accelMagnitude: number | null
  fallDetected: boolean
  motion: string
  signalOk: boolean
  heatIndex: number | null
  timestamp: string
  derived?: Derived
  ambient?: Ambient | null
}

export interface Derived {
  heatIndex: number | null
  heatIndexExtrapolated?: boolean
  heatBand: string
  heatBandLabel: string
  strain: number | null
  restingHr: number | null
  airQuality: string
  envSource: string
  mlScore: number | null
  mlRatio: number | null
  mlAnomalous: boolean | null
}

export interface Ambient {
  tempC: number | null
  humidity: number | null
  aqi: number | null
  pm25: number | null
  description?: string | null
  source: string
}

export interface Alert {
  _id: string
  deviceId: string
  type: string
  severity: 'info' | 'warning' | 'critical'
  message: string
  detail?: string
  snapshot?: Record<string, unknown>
  smsSent?: boolean
  smsError?: string
  smsNote?: string
  acknowledged?: boolean
  timestamp: string
}

export interface DeviceInfo {
  deviceId: string
  wearerName?: string
  profile?: string
  age?: number | null
  sex?: string | null
  emergencyContact?: string
  emergencyContactName?: string
  online?: boolean
  lastSeen?: string
}

export interface DisasterAlert {
  id: string
  hazard: string
  disasterType: string
  severity: 'severe' | 'moderate' | 'minor' | 'unknown'
  rawSeverity: string | null
  severityColour: string | null
  message: string
  area: string | null
  issuedBy: string
  startsAt: string
  endsAt: string | null
  distanceKm: number | null
}

/**
 * Freshness and provenance are separate on purpose: a bundled sample is still
 * a sample however recently it was read, so `isSample` — not `freshness` —
 * decides how the source is labelled.
 */
export interface DisasterContext {
  freshness: 'LIVE' | 'CACHED' | 'STALE' | 'UNAVAILABLE'
  provenance: string
  attribution: string
  isLive: boolean
  isSample: boolean
  updatedAt: string | null
  ageMinutes: number | null
  highestSeverity: string | null
  count: number
  radiusKm: number | null
  lastError: string | null
  alerts: DisasterAlert[]
}

let socket: Socket | null = null

// How long since the last sample before we treat the device as gone.
const OFFLINE_AFTER_MS = 15_000

export function useHealth() {
  const cfg = useRuntimeConfig()
  const apiBase = cfg.public.apiBase as string
  const deviceId = cfg.public.deviceId as string

  // useState keeps one copy of this across every page and across navigation,
  // so switching tabs never drops the live feed.
  const connected = useState<boolean>('hc:connected', () => false)
  const latest = useState<Reading | null>('hc:latest', () => null)
  const trail = useState<Reading[]>('hc:trail', () => [])
  const alerts = useState<Alert[]>('hc:alerts', () => [])
  const device = useState<DeviceInfo | null>('hc:device', () => null)
  const banner = useState<Alert | null>('hc:banner', () => null)
  const disaster = useState<DisasterContext | null>('hc:disaster', () => null)
  const started = useState<boolean>('hc:started', () => false)
  const now = useState<number>('hc:now', () => Date.now())

  /** Rolling window kept in memory for the live sparkline. */
  const TRAIL_MAX = 120

  const pushReading = (r: Reading) => {
    latest.value = r
    trail.value = [...trail.value.slice(-(TRAIL_MAX - 1)), r]
  }

  const deviceOnline = computed(() => {
    if (!latest.value) return false
    return now.value - new Date(latest.value.timestamp).getTime() < OFFLINE_AFTER_MS
  })

  const unacknowledged = computed(() => alerts.value.filter((a) => !a.acknowledged).length)

  const activeCritical = computed(() =>
    alerts.value.find((a) => a.severity === 'critical' && !a.acknowledged) || null
  )

  async function loadHistory(minutes = 30) {
    try {
      const res = await $fetch<{ readings: Reading[] }>(`${apiBase}/api/history/${deviceId}`, {
        query: { minutes, limit: 600 },
      })
      return res.readings || []
    } catch {
      return []
    }
  }

  async function loadAlerts() {
    try {
      const res = await $fetch<{ alerts: Alert[] }>(`${apiBase}/api/alerts/${deviceId}`)
      alerts.value = res.alerts || []
    } catch {
      /* offline — keep whatever the service worker cached */
    }
  }

  async function loadDevice() {
    try {
      const res = await $fetch<{ device: DeviceInfo }>(`${apiBase}/api/devices/${deviceId}`)
      device.value = res.device
    } catch {
      device.value = { deviceId }
    }
  }

  /**
   * Official disaster context. Enrichment only — a failure here leaves
   * `disaster` null and the dashboard renders an explicit "unavailable" state
   * rather than implying an all-clear.
   */
  async function loadDisasterContext() {
    try {
      const res = await $fetch<{ context: DisasterContext }>(
        `${apiBase}/api/disaster-context`,
        { query: { deviceId, limit: 5 } },
      )
      disaster.value = res.context
    } catch {
      disaster.value = null
    }
  }

  async function acknowledge(alertId: string) {
    try {
      await $fetch(`${apiBase}/api/alerts/${alertId}/ack`, { method: 'POST' })
      alerts.value = alerts.value.map((a) => (a._id === alertId ? { ...a, acknowledged: true } : a))
      if (banner.value?._id === alertId) banner.value = null
    } catch {
      /* ignore — the ack is a convenience, not a safety mechanism */
    }
  }

  /** Ask the browser for notification permission, then fire one per critical alert. */
  async function enableNotifications() {
    if (typeof Notification === 'undefined') return false
    if (Notification.permission === 'granted') return true
    const result = await Notification.requestPermission()
    return result === 'granted'
  }

  function notify(alert: Alert) {
    if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return
    try {
      new Notification(
        alert.severity === 'critical' ? 'Critical health alert' : 'Health alert',
        { body: `${alert.message}${alert.detail ? ` — ${alert.detail}` : ''}`, tag: alert._id }
      )
    } catch {
      /* some browsers require notifications to come from the service worker */
    }
  }

  /** Connect the socket and load initial state. Safe to call from any page. */
  function start() {
    if (started.value || !import.meta.client) return
    started.value = true

    socket = io(apiBase, { transports: ['websocket', 'polling'] })

    socket.on('connect', () => {
      connected.value = true
      socket?.emit('subscribe', deviceId)
    })

    socket.on('disconnect', () => { connected.value = false })
    socket.on('connect_error', () => { connected.value = false })

    socket.on('reading:new', (r: Reading) => pushReading(r))

    socket.on('alert:triggered', (a: Alert) => {
      alerts.value = [a, ...alerts.value].slice(0, 200)
      if (a.severity !== 'info') {
        banner.value = a
        notify(a)
        // Warnings fade; a critical alert stays until someone acknowledges it.
        if (a.severity === 'warning') {
          setTimeout(() => { if (banner.value?._id === a._id) banner.value = null }, 12_000)
        }
      }
    })

    // The same alert again, now carrying its SMS delivery outcome.
    socket.on('alert:updated', (a: Alert) => {
      alerts.value = alerts.value.map((x) => (x._id === a._id ? { ...x, ...a } : x))
      if (banner.value?._id === a._id) banner.value = { ...banner.value, ...a }
    })

    socket.on('alert:ack', (a: Alert) => {
      alerts.value = alerts.value.map((x) => (x._id === a._id ? { ...x, acknowledged: true } : x))
      if (banner.value?._id === a._id) banner.value = null
    })

    loadDevice()
    loadAlerts()
    loadHistory(15).then((rows) => { if (rows.length) trail.value = rows.slice(-TRAIL_MAX) })

    // Drives the "device offline" check and the relative timestamps.
    setInterval(() => { now.value = Date.now() }, 1000)
  }

  return {
    apiBase,
    deviceId,
    connected,
    deviceOnline,
    latest,
    trail,
    alerts,
    device,
    disaster,
    banner,
    now,
    unacknowledged,
    activeCritical,
    start,
    loadHistory,
    loadAlerts,
    loadDevice,
    loadDisasterContext,
    acknowledge,
    enableNotifications,
  }
}

/* ------------------------------ small helpers ----------------------------- */

export function timeAgo(ts: string | number | Date, nowMs = Date.now()) {
  const diff = Math.max(0, nowMs - new Date(ts).getTime())
  const s = Math.round(diff / 1000)
  if (s < 5) return 'just now'
  if (s < 60) return `${s}s ago`
  const m = Math.round(s / 60)
  if (m < 60) return `${m}m ago`
  const h = Math.round(m / 60)
  if (h < 24) return `${h}h ago`
  return `${Math.round(h / 24)}d ago`
}

export function clockTime(ts: string | number | Date) {
  return new Date(ts).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
}

export const HEAT_BAND_COLOR: Record<string, string> = {
  safe: '#2fd39f',
  caution: '#9ad14a',
  extreme_caution: '#f0a742',
  danger: '#f4783c',
  extreme_danger: '#ff4f63',
  unknown: '#616e83',
}

/** Names from AppIcon's set — never emoji. */
export const SEVERITY_ICON: Record<string, string> = {
  info: 'info',
  warning: 'warning',
  critical: 'critical',
}

export const SEVERITY_COLOR: Record<string, string> = {
  info: '#46b6f0',
  warning: '#f0a742',
  critical: '#ff4f63',
}

export const ALERT_LABEL: Record<string, string> = {
  tachycardia: 'Elevated heart rate',
  bradycardia: 'Low heart rate',
  hypoxia: 'Low blood oxygen',
  fall: 'Fall detected',
  heat_stress: 'Heat stress',
  air_quality: 'Air quality',
  ml_anomaly: 'Model: unusual pattern',
}
