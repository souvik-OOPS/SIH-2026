import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/models/telemetry_frame.dart';
import '../core/telemetry/reconnect_backoff.dart';
import '../core/telemetry/telemetry_source.dart';
import 'ble_packet_assembler.dart';
import 'ble_permission_service.dart';

class SwasthyaBleProtocol {
  static const deviceName = 'SwasthyaShield-Edge';
  static const serviceUuid = '9d5a0001-9d36-4b60-a680-59ab9204d001';
  static const telemetryCharacteristicUuid =
      '9d5a0002-9d36-4b60-a680-59ab9204d001';
}

/// Live BLE implementation of [TelemetrySource]. It scans only for the
/// project's service UUID and reconnects by resuming a conservative scan loop.
class BleTelemetrySource implements TelemetrySource {
  BleTelemetrySource({
    BlePermissionService? permissions,
    ReconnectBackoff? backoff,
  }) : _permissions = permissions ?? BlePermissionService(),
       _backoff = backoff ?? ReconnectBackoff();

  final BlePermissionService _permissions;
  final ReconnectBackoff _backoff;
  final StreamController<TelemetryFrame> _frames =
      StreamController<TelemetryFrame>.broadcast(sync: true);
  final BlePacketAssembler _assembler = BlePacketAssembler();

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  Timer? _rescanTimer;
  BluetoothDevice? _device;
  TelemetryFrame? _lastFrame;
  bool _running = false;
  bool _connecting = false;

  @override
  Stream<TelemetryFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    if (!await _permissions.requestScanAndConnect()) {
      throw StateError('Nearby-device permission was not granted.');
    }

    _running = true;
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      _handleScanResults,
      onError: _addError,
    );
    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        _backoff.reset();
        unawaited(_startFilteredScan());
      } else {
        _emitDisconnectedFrame();
      }
    });
    await _startFilteredScan();
    _scheduleRescan();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _adapterSubscription?.cancel();
    _adapterSubscription = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    try {
      await FlutterBluePlus.stopScan();
      await _device?.disconnect();
    } on Object {
      // A disconnect during a radio-off transition is already a stopped source.
    }
    _device = null;
    _connecting = false;
    _assembler.reset();
    _emitDisconnectedFrame();
  }

  /// Queues the next scan attempt at the current backoff delay. Cancelled as
  /// soon as a device is found, and reset once a connection actually succeeds.
  void _scheduleRescan() {
    _rescanTimer?.cancel();
    _rescanTimer = null;
    if (!_running || _device != null || _connecting) return;
    _rescanTimer = Timer(_backoff.next(), () async {
      if (!_running || _device != null || _connecting) return;
      await _startFilteredScan();
      _scheduleRescan();
    });
  }

  Future<void> _startFilteredScan() async {
    if (!_running ||
        _device != null ||
        _connecting ||
        FlutterBluePlus.isScanningNow) {
      return;
    }
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(SwasthyaBleProtocol.serviceUuid)],
        timeout: const Duration(seconds: 8),
      );
    } on Object catch (error, stackTrace) {
      _addError(error, stackTrace);
    }
  }

  void _handleScanResults(List<ScanResult> results) {
    if (!_running || _device != null || _connecting || results.isEmpty) return;
    unawaited(_connect(results.first.device));
  }

  Future<void> _connect(BluetoothDevice device) async {
    if (!_running || _connecting || _device != null) return;
    _connecting = true;
    _device = device;

    try {
      await FlutterBluePlus.stopScan();
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          unawaited(_handleDisconnect());
        }
      });
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 12),
      );
      final services = await device.discoverServices();
      final telemetryService = services.where(
        (service) => service.uuid == Guid(SwasthyaBleProtocol.serviceUuid),
      );
      if (telemetryService.isEmpty) {
        throw StateError('SwasthyaShield telemetry service was not found.');
      }
      final telemetryCharacteristic = telemetryService.first.characteristics
          .where(
            (characteristic) =>
                characteristic.uuid ==
                Guid(SwasthyaBleProtocol.telemetryCharacteristicUuid),
          );
      if (telemetryCharacteristic.isEmpty) {
        throw StateError(
          'SwasthyaShield telemetry characteristic was not found.',
        );
      }

      final characteristic = telemetryCharacteristic.first;
      _notificationSubscription = characteristic.onValueReceived.listen(
        _handleNotification,
        onError: _addError,
      );
      await characteristic.setNotifyValue(true);
      _backoff.reset();
      _rescanTimer?.cancel();
      _rescanTimer = null;
    } on Object catch (error, stackTrace) {
      _addError(error, stackTrace);
      await _handleDisconnect();
    } finally {
      _connecting = false;
    }
  }

  void _handleNotification(List<int> bytes) {
    final frame = _assembler.accept(bytes);
    if (frame == null) return;
    _lastFrame = frame;
    _frames.add(frame);
  }

  Future<void> _handleDisconnect() async {
    final device = _device;
    _device = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    try {
      await device?.disconnect();
    } on Object {
      // The device may already be gone; rescan is still the correct recovery.
    }
    _assembler.reset();
    _emitDisconnectedFrame();
    if (_running) _scheduleRescan();
  }

  void _emitDisconnectedFrame() {
    final lastFrame = _lastFrame;
    if (lastFrame != null && !_frames.isClosed) {
      _frames.add(
        lastFrame.copyWith(connectivity: TelemetryConnectivity.disconnected),
      );
    }
  }

  void _addError(Object error, StackTrace stackTrace) {
    if (!_frames.isClosed) _frames.addError(error, stackTrace);
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
