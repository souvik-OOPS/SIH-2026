import 'package:flutter/services.dart';

/// Android runtime permissions kept out of UI and BLE transport code.
class BlePermissionService {
  static const _channel = MethodChannel(
    'in.sih.swasthyashield/ble_permissions',
  );

  Future<bool> requestScanAndConnect() async {
    try {
      return await _channel.invokeMethod<bool>('requestBlePermissions') ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
