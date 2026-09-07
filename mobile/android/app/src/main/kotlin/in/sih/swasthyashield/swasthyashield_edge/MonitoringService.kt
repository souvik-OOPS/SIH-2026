package `in`.sih.swasthyashield.swasthyashield_edge

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** User-started connected-device service. Never starts after a force-stop. */
class MonitoringService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        MonitoringBridge.createChannels(this)
        val notification = MonitoringBridge.ongoing(this, "Connecting to your wearable…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(MonitoringBridge.ongoingId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(MonitoringBridge.ongoingId, notification)
        }
        // BLE callbacks/risk timers must continue with the display off. Released
        // on explicit stop/destruction; held only during opted-in monitoring.
        val manager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SwasthyaShield:monitoring").apply {
            setReferenceCounted(false)
            acquire()
        }
        (application as ShieldApplication).engine()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == MonitoringBridge.stopAction) {
            (application as ShieldApplication).monitoringBridge?.stopFromNotification()
            return START_NOT_STICKY
        }
        getSharedPreferences(MonitoringBridge.preferences, MODE_PRIVATE).edit().putBoolean("requested", true).apply()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        @Volatile var running = false
    }
}
