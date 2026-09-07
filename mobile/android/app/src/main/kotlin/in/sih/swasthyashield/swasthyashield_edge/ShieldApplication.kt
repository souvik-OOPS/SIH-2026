package `in`.sih.swasthyashield.swasthyashield_edge

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.FlutterInjector

/** One engine owns BLE and risk state through activity removal/recreation. */
class ShieldApplication : Application() {
    private var sharedEngine: FlutterEngine? = null
    private var qwenChannel: QwenAssistantChannel? = null
    var monitoringBridge: MonitoringBridge? = null
        private set

    @Synchronized
    fun engine(): FlutterEngine {
        sharedEngine?.let { return it }
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(this)
        loader.ensureInitializationComplete(this, null)
        val engine = FlutterEngine(this)
        sharedEngine = engine
        monitoringBridge = MonitoringBridge(this, engine.dartExecutor.binaryMessenger)
        qwenChannel = QwenAssistantChannel(this, engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return engine
    }
}
