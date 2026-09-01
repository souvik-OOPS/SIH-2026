import 'package:flutter/services.dart';

import '../core/escalation/sms_gateway.dart';

/// [SmsGateway] backed by Android's `SmsManager`, over the same MethodChannel
/// pattern used for BLE permissions.
class AndroidSmsGateway implements SmsGateway {
  static const _channel = MethodChannel('in.sih.swasthyashield/sms');

  @override
  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasSmsPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // Non-Android host (or a unit-test binding): no radio to talk to.
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestSmsPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> send({required String phone, required String message}) async {
    try {
      await _channel.invokeMethod<bool>('sendSms', {
        'phone': phone,
        'message': message,
      });
    } on PlatformException catch (error) {
      throw SmsSendException(error.code, error.message ?? 'SMS send failed');
    } on MissingPluginException {
      throw const SmsSendException(
        'unsupported_platform',
        'Direct SMS is only wired up on Android.',
      );
    }
  }

  @override
  Future<void> openComposer({
    required String phone,
    required String message,
  }) async {
    try {
      await _channel.invokeMethod<bool>('openComposer', {
        'phone': phone,
        'message': message,
      });
    } on PlatformException catch (error) {
      throw SmsSendException(
        error.code,
        error.message ?? 'No SMS app available',
      );
    } on MissingPluginException {
      throw const SmsSendException(
        'unsupported_platform',
        'Direct SMS is only wired up on Android.',
      );
    }
  }
}
