package `in`.sih.swasthyashield.swasthyashield_edge

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private var smsPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestBlePermissions" -> requestBlePermissions(result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, smsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasSmsPermission" -> result.success(hasSmsPermission())
                    "requestSmsPermission" -> requestSmsPermission(result)
                    "sendSms" -> sendSms(
                        call.argument<String>("phone"),
                        call.argument<String>("message"),
                        result,
                    )
                    "openComposer" -> openComposer(
                        call.argument<String>("phone"),
                        call.argument<String>("message"),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestBlePermissions(result: MethodChannel.Result) {
        if (permissionResult != null) {
            result.error("request_in_progress", "Bluetooth permission request already in progress", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(true)
            return
        }

        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val missing = permissions.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()
        if (missing.isEmpty()) {
            result.success(true)
            return
        }

        permissionResult = result
        requestPermissions(missing, bluetoothPermissionRequestCode)
    }

    private fun hasSmsPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestSmsPermission(result: MethodChannel.Result) {
        if (smsPermissionResult != null) {
            result.error("request_in_progress", "SMS permission request already in progress", null)
            return
        }
        if (hasSmsPermission()) {
            result.success(true)
            return
        }
        smsPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.SEND_SMS), smsPermissionRequestCode)
    }

    /**
     * Hands the message to the cellular radio. A success here means "accepted for
     * transmission", not "delivered to the recipient" - the caller must not claim
     * delivery on the strength of this result.
     */
    private fun sendSms(phone: String?, message: String?, result: MethodChannel.Result) {
        if (phone.isNullOrBlank() || message.isNullOrBlank()) {
            result.error("invalid_arguments", "phone and message are required", null)
            return
        }
        if (!hasSmsPermission()) {
            result.error("permission_denied", "SEND_SMS permission is not granted", null)
            return
        }
        try {
            val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
            if (manager == null) {
                result.error("no_sms_manager", "This device exposes no SmsManager", null)
                return
            }
            // An alert carrying vitals easily exceeds a single 160-character part.
            val parts = manager.divideMessage(message)
            if (parts.size > 1) {
                manager.sendMultipartTextMessage(phone, null, parts, null, null)
            } else {
                manager.sendTextMessage(phone, null, message, null, null)
            }
            result.success(true)
        } catch (error: Exception) {
            result.error("send_failed", error.message ?: "SMS send failed", null)
        }
    }

    /**
     * Fallback when SEND_SMS is unavailable: opens the user's SMS app with the
     * alert prefilled. It needs a human tap, so it cannot serve an unconscious
     * user - the caller is responsible for saying so.
     */
    private fun openComposer(phone: String?, message: String?, result: MethodChannel.Result) {
        if (phone.isNullOrBlank() || message.isNullOrBlank()) {
            result.error("invalid_arguments", "phone and message are required", null)
            return
        }
        return try {
            val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$phone")).apply {
                putExtra("sms_body", message)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("composer_failed", error.message ?: "No SMS app available", null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() && grantResults.all {
            it == PackageManager.PERMISSION_GRANTED
        }
        when (requestCode) {
            bluetoothPermissionRequestCode -> {
                permissionResult?.success(granted)
                permissionResult = null
            }
            smsPermissionRequestCode -> {
                smsPermissionResult?.success(granted)
                smsPermissionResult = null
            }
        }
    }

    private companion object {
        const val channelName = "in.sih.swasthyashield/ble_permissions"
        const val smsChannelName = "in.sih.swasthyashield/sms"
        const val bluetoothPermissionRequestCode = 26181
        const val smsPermissionRequestCode = 26182
    }
}
