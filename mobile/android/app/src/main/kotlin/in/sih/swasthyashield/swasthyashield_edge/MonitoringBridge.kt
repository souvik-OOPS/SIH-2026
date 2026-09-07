package `in`.sih.swasthyashield.swasthyashield_edge

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class MonitoringBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "in.sih.swasthyashield/monitoring")
    private val prefs = context.getSharedPreferences(preferences, Context.MODE_PRIVATE)
    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        createChannels(context)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(status())
                    "start" -> {
                        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Manifest.permission.BLUETOOTH_CONNECT else Manifest.permission.BLUETOOTH
                        if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                            result.error("bluetooth_permission", "Allow Nearby devices before starting monitoring.", null)
                        } else {
                            prefs.edit().putBoolean("requested", true).apply()
                            val intent = Intent(context, MonitoringService::class.java)
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
                                result.success(status())
                            } catch (error: Exception) {
                                prefs.edit().putBoolean("requested", false).apply()
                                throw error
                            }
                        }
                    }
                    "stop" -> { stop(); result.success(null) }
                    "update" -> {
                        if (MonitoringService.running) manager.notify(ongoingId, ongoing(context, call.argument<String>("text") ?: "Monitoring connected wearable"))
                        result.success(null)
                    }
                    "alert" -> {
                        if (!notificationsAllowed()) result.success(false) else {
                            val id = call.argument<Int>("id") ?: 26190
                            val title = call.argument<String>("title") ?: "Check your readings"
                            val body = call.argument<String>("body") ?: "Open SwasthyaShield for details."
                            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, alertChannel) else Notification.Builder(context)
                            val notification = builder.setSmallIcon(R.drawable.ic_monitoring)
                                .setContentTitle(title).setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                                .setContentIntent(openApp(context)).setAutoCancel(true).setCategory(Notification.CATEGORY_ALARM)
                                .setVisibility(Notification.VISIBILITY_PRIVATE)
                                .setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL).build()
                            manager.notify(id, notification)
                            result.success(true)
                        }
                    }
                    "settings" -> {
                        context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("monitoring_failed", error.message, null)
            }
        }
    }

    private fun notificationsAllowed(): Boolean {
        val permission = Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val enabled = Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled()
        val channelEnabled = Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(alertChannel)?.importance != NotificationManager.IMPORTANCE_NONE
        return permission && enabled && channelEnabled
    }

    private fun status() = mapOf("requested" to prefs.getBoolean("requested", false), "running" to MonitoringService.running, "notificationsAllowed" to notificationsAllowed())

    private fun stop() {
        prefs.edit().putBoolean("requested", false).apply()
        context.stopService(Intent(context, MonitoringService::class.java))
        manager.cancel(ongoingId)
    }

    fun stopFromNotification() {
        stop()
        channel.invokeMethod("stopped", null)
    }

    companion object {
        const val preferences = "shield_monitoring"
        const val stopAction = "in.sih.swasthyashield.STOP_MONITORING"
        const val ongoingId = 26181
        private const val ongoingChannel = "wearable_monitoring"
        private const val alertChannel = "health_alerts"

        fun createChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(ongoingChannel, "Wearable connection", NotificationManager.IMPORTANCE_LOW).apply { description = "Shows when background monitoring is active" })
            manager.createNotificationChannel(NotificationChannel(alertChannel, "Unusual readings", NotificationManager.IMPORTANCE_HIGH).apply { description = "Sustained unusual vitals, falls, and connection problems"; enableVibration(true) })
        }

        private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        fun ongoing(context: Context, text: String): Notification {
            val stop = PendingIntent.getService(context, 1, Intent(context, MonitoringService::class.java).setAction(stopAction), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, ongoingChannel) else Notification.Builder(context)
            return builder.setSmallIcon(R.drawable.ic_monitoring).setContentTitle("SwasthyaShield monitoring")
                .setContentText(text).setContentIntent(openApp(context)).setOngoing(true)
                .setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE)
                .addAction(Notification.Action.Builder(null, "Stop monitoring", stop).build()).build()
        }
    }
}
