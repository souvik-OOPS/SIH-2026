package `in`.sih.swasthyashield.swasthyashield_edge

import android.Manifest
import android.content.Intent
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import java.io.File
import java.util.concurrent.Executors
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private var smsPermissionResult: MethodChannel.Result? = null
    private var modelImportResult: MethodChannel.Result? = null
    private var notificationPermissionResult: MethodChannel.Result? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine = (application as ShieldApplication).engine()
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "in.sih.swasthyashield/sharing")
            .setMethodCallHandler { call, result ->
                if (call.method != "shareSummary") {
                    result.notImplemented()
                } else {
                    val text = call.argument<String>("text")
                    if (text.isNullOrBlank() || text.length > 16000) {
                        result.error("invalid_summary", "Summary is empty or too long", null)
                    } else try {
                        val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                            .putExtra(Intent.EXTRA_TEXT, text)
                            .putExtra(Intent.EXTRA_TITLE, "SwasthyaShield summary")
                        startActivity(Intent.createChooser(send, "Share summary"))
                        result.success(null) // Chooser opened, not sent/delivered.
                    } catch (error: Exception) {
                        result.error("share_unavailable", error.message, null)
                    }
                }
            }
        // These permission/document operations require the visible Activity.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestBlePermissions" -> requestBlePermissions(result)
                    "importModel" -> {
                        if (modelImportResult != null) result.error("import_in_progress", "A model import is already open", null)
                        else {
                            modelImportResult = result
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE), 26184)
                        }
                    }
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) result.success(true)
                        else if (notificationPermissionResult != null) result.error("request_in_progress", "Notification permission request in progress", null)
                        else { notificationPermissionResult = result; requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 26183) }
                    }
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
            26183 -> { notificationPermissionResult?.success(granted); notificationPermissionResult = null }
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

    override fun onDestroy() {
        super.onDestroy()
    }

    @Deprecated("Activity result bridge for Flutter model import")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 26184) return
        val result = modelImportResult ?: return
        modelImportResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) { result.success(false); return }
        val worker = Executors.newSingleThreadExecutor()
        worker.execute {
            val partial = File(filesDir, "qwen.gguf.import")
            try {
                contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "Cannot open model file" }
                    partial.outputStream().use { out ->
                        val header = ByteArray(4)
                        require(input.read(header) == 4 && header.toString(Charsets.US_ASCII) == "GGUF") { "Select a GGUF model file" }
                        out.write(header)
                        val buffer = ByteArray(1024 * 1024)
                        var total = 4L
                        while (true) {
                            val n = input.read(buffer); if (n < 0) break
                            total += n; require(total <= 1500L * 1024 * 1024) { "Choose the small Qwen3-0.6B model" }
                            out.write(buffer, 0, n)
                        }
                    }
                }
                require(partial.renameTo(QwenRuntime.modelFile(this))) { "Could not save model" }
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                partial.delete()
                runOnUiThread { result.error("import_failed", error.message, null) }
            } finally { worker.shutdown() }
        }
    }

    private companion object {
        const val channelName = "in.sih.swasthyashield/ble_permissions"
        const val smsChannelName = "in.sih.swasthyashield/sms"
        const val bluetoothPermissionRequestCode = 26181
        const val smsPermissionRequestCode = 26182
    }
}
